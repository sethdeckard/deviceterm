// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Bounds how long a caller waits for a display bootstrap, and how many creates
/// can be admitted to start one at a time. A slot is taken before the backend is
/// acquired and held until the pane publishes or disposal finishes, so the cap
/// covers the whole attempt rather than the bootstrap call alone.
///
/// `DeviceBackend.bootstrapDisplay` frees the calling actor but bounds nothing:
/// under it are synchronous, uncancellable bridge calls, so a wedged service
/// parks the attempt forever. This is the accounting `SimBackendAcquirer`
/// applies to acquisition, for the same reason and with the same two-lifetime
/// rule.
///
/// A caller's wait and the underlying attempt have **different lifetimes**. A
/// timeout stops the caller waiting; the attempt keeps running and keeps its
/// slot until the bridge answers *and* the teardown that follows finishes,
/// which is what bounds how many wedged starts can pile up. Whatever a late
/// attempt produces is torn down rather than delivered, because the pane it
/// was for is gone.
///
/// The cap is global rather than per-pane: it exists to bound total parked
/// bridge work, which is a property of the machine, not of one pane.
actor DisplayBootstrapSupervisor {
    /// One outstanding bootstrap. The entry outlives the caller's wait, which
    /// is what makes an abandoned attempt keep holding its slot.
    private struct Attempt {
        let udid: String
        /// Nil between admission and the bootstrap call: a slot is reserved
        /// before a backend exists, which is what keeps a refusal from having
        /// acquired one.
        var backend: (any DeviceBackend)?
        /// Nil between admission and the bootstrap call. Afterwards it holds
        /// the deadline task for the life of the entry, cancelled but still
        /// present once the attempt settles.
        let timeoutTask: Task<Void, Never>?
        /// Caller-owned cleanup for an abandoned attempt, run after the
        /// backend is torn down. The device path releases its tunnel keepalive
        /// here: doing it at the timeout instead would pull the transport out
        /// from under a bootstrap that is still running.
        let onDisposed: @Sendable () async -> Void
        var continuation: CheckedContinuation<DisplayBootstrap, any Error>?
    }

    /// How long a caller waits before its bootstrap is abandoned.
    static let defaultDeadlineNanoseconds: UInt64 = 10_000_000_000
    /// Ceiling on attempts holding a slot, abandoned ones included.
    static let defaultMaxInFlight = 3

    private let deadlineNanoseconds: UInt64
    private let maxInFlight: Int
    private let sleep: @Sendable (UInt64) async throws -> Void
    private var attempts: [UUID: Attempt] = [:]

    /// Attempts currently holding a slot, abandoned ones included. Read by the
    /// footprint sample and the daemon lifetime predicate, so an idle exit
    /// cannot fire while an admitted attempt is still acquiring, bootstrapping,
    /// or disposing.
    var inFlight: Int { attempts.count }

    init(
        deadlineNanoseconds: UInt64 = DisplayBootstrapSupervisor.defaultDeadlineNanoseconds,
        maxInFlight: Int = DisplayBootstrapSupervisor.defaultMaxInFlight,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) {
        self.deadlineNanoseconds = deadlineNanoseconds
        self.maxInFlight = max(1, maxInFlight)
        self.sleep = sleep
    }

    /// Release a bootstrap nobody will be handed, whatever it returned.
    ///
    /// A success has started frames and installed observation against a pane
    /// that no longer exists. A failure needs the same treatment for a
    /// different reason: the lane cleans up its own partial start, but the
    /// backend it was starting stays acquired, and no pane will ever own it.
    private static func dispose(backend: any DeviceBackend) async {
        await backend.shutdownBackendAsync()
    }

    /// Reserve a slot before acquiring a backend.
    ///
    /// Admission has to happen *before* acquisition, not at the bootstrap call.
    /// Refusing afterwards means every refused request has already built a
    /// backend that then needs tearing down, so refusals themselves accumulate
    /// stalled teardowns and the cap bounds nothing.
    ///
    /// The slot is held until `release` (the pane published) or a disposal
    /// finishes, whichever comes first.
    func admit(udid: String) throws -> UUID {
        guard attempts.count < maxInFlight else {
            throw PaneError.displayStartBusy(udid: udid)
        }
        let token = UUID()
        attempts[token] = Attempt(
            udid: udid,
            backend: nil,
            timeoutTask: nil,
            onDisposed: {},
            continuation: nil
        )
        return token
    }

    /// Give back a slot whose work finished without needing teardown, or that
    /// was never used. A no-op once the slot has already been settled.
    func release(token: UUID) {
        attempts.removeValue(forKey: token)
    }

    /// Tear down a handed-over backend under the token it was admitted on, so
    /// a rejected handoff reuses its slot instead of adding one.
    func disposeAdmitted(
        token: UUID,
        backend: any DeviceBackend,
        onDisposed: @escaping @Sendable () async -> Void = {}
    ) async {
        await Self.dispose(backend: backend)
        await onDisposed()
        attempts.removeValue(forKey: token)
    }

    /// Bootstrap `backend`'s display under an already-admitted token, waiting
    /// no longer than the deadline.
    ///
    /// Throws `PaneError.displayStartTimedOut` when the deadline wins. Capacity
    /// was decided by `admit`, so the only `displayStartBusy` from here is an
    /// unknown token, which is unreachable and disposes the backend rather than
    /// leaking it.
    func bootstrap(
        token: UUID,
        backend: any DeviceBackend,
        udid: String,
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void,
        onDisconnect: @escaping @Sendable () -> Void,
        onOrientation: @escaping @Sendable (Orientation) -> Void,
        onDisposed: @escaping @Sendable () async -> Void = {}
    ) async throws -> DisplayBootstrap {
        guard attempts[token] != nil else {
            // Unreachable: admission precedes this call. Dispose rather than
            // leaking a backend nobody will own.
            await Self.dispose(backend: backend)
            await onDisposed()
            throw PaneError.displayStartBusy(udid: udid)
        }
        start(
            token: token,
            udid: udid,
            backend: backend,
            onFrame: onFrame,
            onFatal: onFatal,
            onDisconnect: onDisconnect,
            onOrientation: onOrientation,
            onDisposed: onDisposed
        )
        return try await withCheckedThrowingContinuation { continuation in
            // Runs synchronously in the same actor step as `start`, so neither
            // task it spawned can have looked for the continuation before it is
            // installed.
            guard var attempt = attempts[token] else {
                continuation.resume(throwing: PaneError.displayStartTimedOut(udid: udid))
                return
            }
            attempt.continuation = continuation
            attempts[token] = attempt
        }
    }

    /// Spawn one attempt's work, its deadline, and the supervisor that accounts
    /// for whatever the work eventually produces. All three are unstructured
    /// because a caller giving up cannot cancel the bridge calls underneath.
    private func start(
        token: UUID,
        udid: String,
        backend: any DeviceBackend,
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void,
        onDisconnect: @escaping @Sendable () -> Void,
        onOrientation: @escaping @Sendable (Orientation) -> Void,
        onDisposed: @escaping @Sendable () async -> Void
    ) {
        let work = Task { () -> Result<DisplayBootstrap, any Error> in
            do {
                return .success(
                    try await backend.bootstrapDisplay(
                        onFrame: onFrame,
                        onFatal: onFatal,
                        onDisconnect: onDisconnect,
                        onOrientation: onOrientation
                    )
                )
            } catch {
                return .failure(error)
            }
        }
        let deadlineNanoseconds = self.deadlineNanoseconds
        let sleep = self.sleep
        let timeoutTask = Task { [weak self] in
            // A cancelled sleep means the attempt already settled; `try?` would
            // turn that into a spurious timeout.
            do {
                try await sleep(deadlineNanoseconds)
            } catch {
                return
            }
            await self?.timeOut(token: token)
        }
        attempts[token] = Attempt(
            udid: udid,
            backend: backend,
            timeoutTask: timeoutTask,
            onDisposed: onDisposed,
            continuation: attempts[token]?.continuation
        )
        Task { [weak self] in
            let result = await work.value
            guard let self else {
                await Self.dispose(backend: backend)
                return
            }
            await self.complete(token: token, backend: backend, result: result)
        }
    }

    /// Stop the caller waiting. The attempt keeps running and keeps its slot,
    /// which is what bounds how many wedged starts can pile up.
    private func timeOut(token: UUID) {
        guard var attempt = attempts[token], let continuation = attempt.continuation else { return }
        attempt.continuation = nil
        attempts[token] = attempt
        let deadlineMilliseconds = deadlineNanoseconds / 1_000_000
        let held = attempts.count
        let cap = maxInFlight
        DiagnosticLog.attach.error(
            """
            display bootstrap timed out after \
            \(deadlineMilliseconds, privacy: .public)ms; \
            \(held, privacy: .public) of \(cap, privacy: .public) slots held
            """
        )
        continuation.resume(throwing: PaneError.displayStartTimedOut(udid: attempt.udid))
    }

    /// Account for a finished attempt: hand an in-deadline success to its
    /// caller, and tear down everything else, both failures and anything that
    /// arrives after the deadline answered the caller.
    private func complete(
        token: UUID,
        backend: any DeviceBackend,
        result: Result<DisplayBootstrap, any Error>
    ) async {
        guard var attempt = attempts[token] else {
            await Self.dispose(backend: backend)
            return
        }
        attempt.timeoutTask?.cancel()
        if let continuation = attempt.continuation, case .success = result {
            // Handed over, but the slot is *not* freed here. The caller's
            // ownership fence can still reject this pane, and disposing that
            // rejection under a fresh entry would let repeated rejected
            // handoffs pile up past the cap. The caller settles the token:
            // `release` once the pane is published, `disposeAdmitted` if it
            // rejects.
            attempt.continuation = nil
            attempts[token] = attempt
            continuation.resume(with: result)
            return
        }
        // Everything else is disposed here, holding the slot until teardown
        // finishes. The caller is answered first so an error still returns
        // promptly, but the admission accounting stays charged: otherwise
        // failures for different targets could pile up stalled bridge
        // teardowns while `inFlight` read below the cap.
        if let continuation = attempt.continuation {
            attempt.continuation = nil
            attempts[token] = attempt
            continuation.resume(with: result)
        }
        // The slot stays held across the teardown, not just across the bridge
        // call: `shutdownBackendAsync` can stall on the same wedged lane, and
        // releasing here would report the attempt gone while its display is
        // still being torn down. That would let the daemon idle-exit out from
        // under it and let further attempts pile up behind it.
        if let backend = attempt.backend {
            await Self.dispose(backend: backend)
        }
        await attempt.onDisposed()
        attempts.removeValue(forKey: token)
    }
}
