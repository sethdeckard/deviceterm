// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import Foundation
import os

/// Builds a simulator pane's bridge handles without occupying the pane actor.
///
/// Every lookup this performs is a synchronous CoreSimulator round-trip, and a
/// service that stops answering parks its caller with no timeout of its own.
/// Run inline on `PaneCoordinator`, that park lands on the actor's executor,
/// where it also stops every unrelated `pane.*` request, the idle-exit
/// predicate, and session teardown. Confining it here separates the two halves:
/// the work runs on a Dispatch queue, and the *wait*, which a caller can safely
/// abandon, gets a deadline.
///
/// The queue is concurrent so a fresh attempt does not queue behind a parked
/// one, and `maxInFlight` is what keeps that from growing threads without
/// bound. A parked attempt holds its slot until CoreSimulator answers, so the
/// count includes attempts whose caller already gave up, and a caller arriving
/// past the cap is refused rather than adding another parked thread.
///
/// An acquisition that lands after its deadline is torn down rather than
/// dropped: it owns live display and HID handles that no pane record will ever
/// close.
actor SimBackendAcquirer {
    typealias Acquired = PaneCoordinator.AcquiredBackend

    /// One attempt's bookkeeping. `continuation` is cleared as soon as the
    /// caller has an answer, from the work or from the deadline; the entry
    /// outlives it and is removed only when the work returns, which is what
    /// makes an abandoned attempt keep holding its slot.
    private struct Attempt {
        let udid: String
        let timeoutTask: Task<Void, Never>
        var continuation: CheckedContinuation<Acquired, any Error>?
    }

    /// Reports each completed backend build, and the disposal of a backend
    /// that returned after its deadline. The log is the only record of which
    /// client a pane's input goes through: a replacement daemon builds a
    /// fresh HID client for a sim the previous one was already driving, and
    /// nothing on the wire says so.
    enum Event: Equatable, Sendable {
        /// A backend, and with it a HID client, now exists for this sim.
        /// `acquisition` numbers every backend this acquirer built and is
        /// what the pane that publishes on it logs; `ordinal` counts the
        /// backends built for the same udid, so a second one marks a
        /// re-attach or a lost race.
        case backendBuilt(udid: String, acquisition: Int, ordinal: Int)
        /// The backend returned after its caller gave up, and was torn down.
        case disposed(udid: String, acquisition: Int)
    }

    /// How long a caller waits before its acquisition is abandoned.
    static let defaultDeadlineNanoseconds: UInt64 = 10_000_000_000
    /// Ceiling on attempts holding a slot, abandoned ones included.
    static let defaultMaxInFlight = 3

    private let queue: BlockingWorkQueue
    private let acquireHandles: @Sendable (String) throws -> Acquired
    private let deadlineNanoseconds: UInt64
    private let maxInFlight: Int
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let report: @Sendable (Event) -> Void
    private var attempts: [UUID: Attempt] = [:]
    /// Backends built per udid over this process's life, never decremented.
    private var backendsBuilt: [String: Int] = [:]
    /// Backends built in total; the last value handed out is the newest
    /// backend's acquisition number.
    private var acquisitionsCompleted = 0

    /// Attempts currently holding a slot, abandoned ones included. Diagnostic
    /// for tests; the daemon never branches on it.
    var inFlight: Int { attempts.count }

    init(
        deadlineNanoseconds: UInt64 = SimBackendAcquirer.defaultDeadlineNanoseconds,
        maxInFlight: Int = SimBackendAcquirer.defaultMaxInFlight,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        acquireHandles: @escaping @Sendable (String) throws -> Acquired = {
            try SimBackendAcquirer.acquireFromBridge(udid: $0)
        },
        report: @escaping @Sendable (Event) -> Void = { SimBackendAcquirer.log($0) }
    ) {
        self.queue = BlockingWorkQueue(
            label: "com.deviceterm.daemon.sim-backend-acquire",
            attributes: .concurrent
        )
        self.deadlineNanoseconds = deadlineNanoseconds
        self.maxInFlight = max(1, maxInFlight)
        self.sleep = sleep
        self.acquireHandles = acquireHandles
        self.report = report
    }

    /// The default reporter. The udid stays private per `DiagnosticLog`;
    /// `acquisition` matches the pane-published record even when concurrent
    /// attaches interleave.
    private static func log(_ event: Event) {
        switch event {
        case let .backendBuilt(udid, acquisition, ordinal):
            DiagnosticLog.attach.notice(
                """
                simulator backend built: acquisition=\(acquisition, privacy: .public) \
                hid client \(ordinal, privacy: .public) for this sim in this process; \
                udid=\(udid, privacy: .private)
                """
            )

        case let .disposed(udid, acquisition):
            DiagnosticLog.attach.notice(
                """
                simulator backend acquisition returned after its deadline; \
                handles released; acquisition=\(acquisition, privacy: .public) \
                udid=\(udid, privacy: .private)
                """
            )
        }
    }

    /// Acquire the CoreSimulator bridge handles for a sim pane and wrap them in
    /// a `SimDeviceBackend`. Classifies the device family and human-readable
    /// type up front (best-effort, since a lookup failure leaves the pane
    /// usable with an unknown family), so every attach path gets them from the
    /// daemon's response. An unusable sim (display, HID, or Purple acquisition
    /// failure) surfaces before the pane is recorded.
    static func acquireFromBridge(udid normalized: String) throws -> Acquired {
        let handle = try? SimDeviceHandle.handle(forUDID: normalized)
        let family = (
            handle
            .map { DeviceFamilyClassifier.classify($0.deviceTypeIdentifier) }
            ?? .unknown
            ).rawValue
        let deviceType: String? = handle.flatMap {
            $0.deviceTypeName.isEmpty ? nil : $0.deviceTypeName
        }
        let displayHandle: SimDisplayHandle
        do {
            displayHandle = try SimDisplayHandle.handle(forUDID: normalized)
        } catch {
            throw PaneError.deviceNotFound(udid: normalized)
        }
        // Acquire HID + Purple clients up front. Both go through the
        // same bridge load + sim lookup as the display handle, so
        // failures here mean the sim isn't actually usable, so surface
        // them before we record the pane.
        let hidClient: SimHIDClient
        do {
            hidClient = try SimHIDClient.client(forUDID: normalized)
        } catch {
            throw PaneError.hidUnavailable(
                udid: normalized,
                message: BridgeMessage.unwrap(error)
            )
        }
        let purpleClient: SimPurpleHID
        do {
            purpleClient = try SimPurpleHID.client(forUDID: normalized)
        } catch {
            throw PaneError.hidUnavailable(
                udid: normalized,
                message: BridgeMessage.unwrap(error)
            )
        }
        let backend = SimDeviceBackend(
            udid: normalized,
            displayHandle: displayHandle,
            hidClient: hidClient,
            purpleClient: purpleClient
        )
        return Acquired(backend: backend, family: family, deviceType: deviceType)
    }

    /// Release an acquisition nobody will be handed. Its handles are live
    /// CoreSimulator resources and no pane record exists to close them.
    private static func dispose(_ result: Result<Acquired, any Error>) {
        guard case let .success(acquired) = result else { return }
        acquired.backend.shutdownBackend()
    }

    /// Build the backend for `udid`, waiting no longer than the deadline.
    ///
    /// Throws `PaneError.backendAcquireBusy` when every slot is taken, and
    /// `PaneError.backendAcquireTimedOut` when the deadline passes first. A
    /// busy result starts no work. A timeout stops waiting but leaves the
    /// synchronous bridge call running and holding its slot, since nothing can
    /// cancel one. Retry after a slot frees.
    func acquire(udid: String) async throws -> Acquired {
        guard attempts.count < maxInFlight else {
            throw PaneError.backendAcquireBusy(udid: udid)
        }
        let token = UUID()
        start(token: token, udid: udid)
        return try await withCheckedThrowingContinuation { continuation in
            // This body runs synchronously in the same actor step as `start`,
            // so neither task it spawned can have looked for the continuation
            // before it is installed.
            guard var attempt = attempts[token] else {
                continuation.resume(throwing: PaneError.backendAcquireTimedOut(udid: udid))
                return
            }
            attempt.continuation = continuation
            attempts[token] = attempt
        }
    }

    /// Spawn one attempt's work, its deadline, and the supervisor that accounts
    /// for whatever the work eventually produces. All three are unstructured
    /// because a caller giving up cannot cancel the bridge call underneath.
    private func start(token: UUID, udid: String) {
        let queue = self.queue
        let acquireHandles = self.acquireHandles
        let work = Task { () -> Result<Acquired, any Error> in
            do {
                return .success(try await queue.run { try acquireHandles(udid) })
            } catch {
                return .failure(error)
            }
        }
        let deadlineNanoseconds = self.deadlineNanoseconds
        let sleep = self.sleep
        let timeoutTask = Task { [weak self] in
            // A cancelled sleep means the attempt already settled; `try?`
            // would turn that into a spurious timeout.
            do {
                try await sleep(deadlineNanoseconds)
            } catch {
                return
            }
            await self?.timeOut(token: token)
        }
        attempts[token] = Attempt(udid: udid, timeoutTask: timeoutTask, continuation: nil)
        Task { [weak self] in
            let result = await work.value
            guard let self else {
                Self.dispose(result)
                return
            }
            await self.complete(token: token, result: result)
        }
    }

    /// Stop the caller waiting. The attempt keeps running and keeps its slot,
    /// which is what bounds how many threads a wedged service can park.
    private func timeOut(token: UUID) {
        guard var attempt = attempts[token], let continuation = attempt.continuation else { return }
        attempt.continuation = nil
        attempts[token] = attempt
        let deadlineMilliseconds = deadlineNanoseconds / 1_000_000
        let held = attempts.count
        let cap = maxInFlight
        DiagnosticLog.attach.error(
            """
            simulator backend acquisition timed out after \
            \(deadlineMilliseconds, privacy: .public)ms; \
            \(held, privacy: .public) of \(cap, privacy: .public) slots held
            """
        )
        continuation.resume(throwing: PaneError.backendAcquireTimedOut(udid: attempt.udid))
    }

    /// Account for a finished attempt: hand it to its caller, or tear it down
    /// when the deadline already answered them.
    private func complete(token: UUID, result: Result<Acquired, any Error>) {
        guard let attempt = attempts.removeValue(forKey: token) else {
            Self.dispose(result)
            return
        }
        attempt.timeoutTask.cancel()
        var result = result
        var acquisition: Int?
        if case let .success(acquired) = result {
            acquisitionsCompleted += 1
            let ordinal = (backendsBuilt[attempt.udid] ?? 0) + 1
            backendsBuilt[attempt.udid] = ordinal
            acquisition = acquisitionsCompleted
            result = .success(acquired.numbered(acquisitionsCompleted))
            report(.backendBuilt(udid: attempt.udid, acquisition: acquisitionsCompleted, ordinal: ordinal))
        }
        guard let continuation = attempt.continuation else {
            Self.dispose(result)
            if let acquisition {
                report(.disposed(udid: attempt.udid, acquisition: acquisition))
            }
            return
        }
        continuation.resume(with: result)
    }
}
