// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeviceCoordinator: the daemon's actor for sim lifecycle and
// provenance.
//
// CoreSimulator owns the actual simulator processes; we hold thin
// `SimDeviceHandle` references transiently and track *which sims we own*
// and, where there is one, the session attributed to each. The ownership map
// is the trust anchor for
// `device.list({scope: "owned"})` and for the menu bar's
// running-sim badge count, and is updated by:
//
//   - `reconcileBootClaim`, which promotes a causally bounded GUI or shim
//     attempt only after CoreSimulator reports Booted.
//   - `transferOwnership`, reached by `device.attach` when the user claims an
//     already-Booted sim without inventing a lifecycle event.
//   - `recordOwnership`, retained for compatibility and test setup.
//   - `restoreOwnership`, reached by `device.restoreOwnership` when a
//     validated GUI restores its claims to a daemon that restarted under
//     it. It changes bookkeeping without booting a sim or publishing
//     `device.booted`.
//
// Entries are removed by daemon shutdowns, shim-reported shutdown events, and
// CoreSimulator shutdown notifications.
//
// Handles never escape this actor: every public method either
// returns a `Sendable` snapshot (`CSBDeviceInfo`) or just an ack.
// The `SimDeviceHandle` is reacquired inside each call's actor-
// isolated body and dropped before the call returns. That matches
// the contract in `SimDeviceHandle.h` ("transient lookup result
// within a serializing context").

import CoreSimulatorBridge
import DaemonProtocol
import Foundation

public actor DeviceCoordinator {
    private struct BootClaimRecord {
        var evidence: BootClaimEvidence
        var sessionId: UUID?
        let expiresAtNanoseconds: UInt64
        var status: BootClaimStatus
    }

    /// What a closed session's devices should become.
    ///
    /// A bare `PaneCloseMode` can only say detach or shut down, which cannot
    /// express the case a shared tab creates: the session is leaving but
    /// siblings remain, so the device changes hands instead of going away.
    /// The incarnation the verdict was recorded for rides along so a claim
    /// from the same UUID restored at a newer incarnation is not
    /// dispositioned by its predecessor's close. An incarnation-less
    /// tombstone (the compatibility arm) applies to every claim naming the
    /// session, whatever its incarnation.
    private struct ClosedBootSession {
        let outcome: CohortCloseOutcome
        let incarnation: UInt64?
        let expiresAtNanoseconds: UInt64
    }

    private struct CachedDeviceRead {
        let result: CoreSimulatorDeviceReadResult
        let completedAtNanoseconds: UInt64
    }

    private enum DeviceReadResult: Sendable {
        case completed(CoreSimulatorDeviceReadResult)
        case timedOut
    }

    private enum DeviceReadWaitResult: Sendable {
        case completed(CoreSimulatorDeviceReadResult, generation: UInt64)
        case retry
        case timedOut
    }

    private struct InFlightDeviceRead {
        let token: UUID
        let generation: UInt64
        let startedAtNanoseconds: UInt64
        let task: Task<CoreSimulatorDeviceReadResult, Never>
        let timeoutTask: Task<Void, Never>
        var waiters: [CheckedContinuation<DeviceReadWaitResult, Never>]
        var timedOut: Bool
    }

    private static let defaultDeviceSnapshotTTLNanoseconds: UInt64 = 2_000_000_000
    private static let defaultDeviceSnapshotDeadlineNanoseconds: UInt64 = 3_000_000_000
    private static let bootClaimTerminalRetentionNanoseconds: UInt64 = 60_000_000_000

    /// UDID (lowercased) → the session attributed to it, or nil for one
    /// explicitly claimed without an attribution. Cleared when the sim shuts
    /// down.
    ///
    /// A present key means deviceterm owns the sim; the value is only its
    /// attribution. Those are separate facts: a tab closed with Detach ends
    /// its session while the sim keeps running and stays ours, which the
    /// status item lists under "Unlinked". A stored UUID naming a session
    /// that has since closed resolves the same way there.
    ///
    /// Reach it through `owns(_:)` and `owner(of:)` rather than subscripting,
    /// so the two levels never get confused: a bare subscript yields a double
    /// optional, the outer being ownership and the inner attribution.
    private var ownership: [String: UUID?] = [:]
    private var bootClaims: [UUID: BootClaimRecord] = [:]
    private var activeBootClaimByUDID: [String: UUID] = [:]
    private var bootClaimPoller: Task<Void, Never>?
    private var closedBootSessions: [UUID: ClosedBootSession] = [:]
    private var closedBootSessionCleaner: Task<Void, Never>?
    /// Optional event broker. Publishes `device.booted` + `device.shutdown`
    /// to every session's `deviceterm events` subscribers (device events
    /// are `.everyone`).
    private let eventBroker: EventBroker?

    /// CoreSimulator notification subscription. Held for the
    /// daemon's lifetime so set-level notifications continue to
    /// arrive. Nil until `subscribeToCoreSimulator(paneShutdownConverger:)`
    /// is called and after `unsubscribeFromCoreSimulator()` runs.
    ///
    /// `CSBDeviceNotifier` isn't `Sendable` (instance methods reach
    /// private framework state); keeping it inside the actor means
    /// it never crosses an isolation boundary.
    private var notifier: CSBDeviceNotifier?

    /// Drives every pane attached to a shut-down UDID into `.shutdown`.
    /// Supplied by `subscribeToCoreSimulator(paneShutdownConverger:)`
    /// rather than at construction, since a coordinator that never
    /// subscribes never observes an external shutdown. Module-internal
    /// rather than private so the notification tests can drive
    /// convergence without registering a real CoreSimulator subscription.
    var paneShutdownConverger: (@Sendable (String) async -> Void)?

    /// Continuation for the `AsyncStream<NotifierArrival>` that
    /// the bridge handler yields into. Held so `unsubscribe…` can
    /// `finish()` the stream and the consumer task can exit.
    private var notifierContinuation: AsyncStream<NotifierArrival>.Continuation?

    /// Long-lived consumer task driving `for await arrival in stream`.
    /// Naturally actor-isolated, serial, and a single allocation
    /// for the daemon's lifetime, versus a `Task { await … }` per
    /// event, which would scatter ordering across reentrancy.
    private var notifierConsumer: Task<Void, Never>?

    /// Last authoritative (promoted claim or compatibility ownership record)
    /// `deviceBooted` publish per UDID. Used by the notification
    /// path to debounce a follow-up `noteExternalBoot` that lands
    /// after the authoritative one fired for the same boot. NOT
    /// consulted by authoritative publishers themselves. Back-to-
    /// back shim records (e.g. session B reclaiming session A's
    /// UDID) are distinct real events and must each fire.
    private var recentAuthoritativeBoots: [String: Date] = [:]
    /// Last notification-path `deviceBooted` publish per UDID.
    /// Used by authoritative publishers to debounce a shim record
    /// that lands after the notification fired for the same boot,
    /// and by the notification path to debounce itself against
    /// duplicate notifications.
    private var recentNotificationBoots: [String: Date] = [:]
    /// Shutdown mirrors: same shape, same semantics.
    private var recentAuthoritativeShutdowns: [String: Date] = [:]
    private var recentNotificationShutdowns: [String: Date] = [:]
    /// How long after a publish to suppress duplicates from the
    /// other source. 500 ms is comfortably wider than the observed
    /// shim-vs-notification skew and well below the shortest sim
    /// boot→render time, so it can't accidentally suppress a real
    /// successor event. Injectable so tests covering "work slower than
    /// the window" can shrink it instead of sleeping half a second each.
    private let debounceWindow: TimeInterval
    /// Runs synchronous CoreSimulator enumeration on a serial DispatchQueue,
    /// outside Swift's cooperative executor. Every production snapshot
    /// enumeration reaches this source.
    private let deviceReader: CoreSimulatorDeviceReader
    /// Successful and failed reads share one short TTL. Caching failure avoids
    /// hammering a degraded service, while callers still receive their existing
    /// throw / "can't confirm" result rather than a stale successful snapshot.
    private let deviceSnapshotTTLNanoseconds: UInt64
    private let deviceSnapshotClock: @Sendable () -> UInt64
    private let deviceSnapshotDeadlineNanoseconds: UInt64
    private let deviceSnapshotSleep: @Sendable (UInt64) async throws -> Void
    /// Hermetic restoration tests inject the booted set directly because
    /// `CSBDeviceInfo` has no public fixture initializer. Nil in production;
    /// every production boot-state read derives from `deviceReader`.
    private let bootedUDIDsOverride: (@Sendable () -> Set<String>?)?
    private var cachedDeviceRead: CachedDeviceRead?
    private var inFlightDeviceRead: InFlightDeviceRead?
    /// Incremented synchronously with every observed or commanded device-state
    /// change. Completed reads from an older generation are discarded. Active
    /// waiters retry under the current generation; timed-out waiters retain
    /// their timeout result.
    private var deviceSnapshotGeneration: UInt64 = 0

    /// Diagnostic accessor: raw size of the ownership map, i.e. how
    /// many sims deviceterm considers itself the owner of. Tests only;
    /// it does not reflect live boot state, so nothing user-facing
    /// derives from it. The status item counts `listOwnedBooted()`.
    public var ownedCount: Int { ownership.count }

    /// Whether the CoreSimulator notification subscription is
    /// currently installed. Diagnostic for tests; the daemon never
    /// branches on this in production.
    public var isSubscribedToCoreSimulator: Bool { notifier != nil }

    public init(
        eventBroker: EventBroker? = nil,
        debounceWindow: TimeInterval = 0.5
    ) {
        self.eventBroker = eventBroker
        self.debounceWindow = debounceWindow
        self.deviceReader = CoreSimulatorDeviceReader()
        self.deviceSnapshotTTLNanoseconds = Self.defaultDeviceSnapshotTTLNanoseconds
        self.deviceSnapshotClock = { DispatchTime.now().uptimeNanoseconds }
        self.deviceSnapshotDeadlineNanoseconds = Self.defaultDeviceSnapshotDeadlineNanoseconds
        self.deviceSnapshotSleep = { try await Task.sleep(nanoseconds: $0) }
        self.bootedUDIDsOverride = nil
    }

    /// Module-internal restoration seam. Production never installs a separate
    /// boot-state reader: it derives the set from the shared device snapshot.
    init(
        eventBroker: EventBroker? = nil,
        debounceWindow: TimeInterval = 0.5,
        readBootedUDIDs: @escaping @Sendable () -> Set<String>?
    ) {
        self.eventBroker = eventBroker
        self.debounceWindow = debounceWindow
        self.deviceReader = CoreSimulatorDeviceReader()
        self.deviceSnapshotTTLNanoseconds = Self.defaultDeviceSnapshotTTLNanoseconds
        self.deviceSnapshotClock = { DispatchTime.now().uptimeNanoseconds }
        self.deviceSnapshotDeadlineNanoseconds = Self.defaultDeviceSnapshotDeadlineNanoseconds
        self.deviceSnapshotSleep = { try await Task.sleep(nanoseconds: $0) }
        self.bootedUDIDsOverride = readBootedUDIDs
    }

    /// Module-internal cache seam: tests control the reader, serial queue,
    /// monotonic clock, and TTL without touching CoreSimulator.
    init(
        eventBroker: EventBroker? = nil,
        debounceWindow: TimeInterval = 0.5,
        deviceSnapshotTTLNanoseconds: UInt64 = 2_000_000_000,
        deviceSnapshotClock: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        deviceSnapshotDeadlineNanoseconds: UInt64 = 3_000_000_000,
        deviceSnapshotSleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        deviceReaderQueue: DispatchQueue = DispatchQueue(
            label: "com.deviceterm.daemon.coresimulator-devices.test"
        ),
        readDevices: @escaping @Sendable () throws -> [CSBDeviceInfo]
    ) {
        self.eventBroker = eventBroker
        self.debounceWindow = debounceWindow
        self.deviceReader = CoreSimulatorDeviceReader(
            queue: deviceReaderQueue,
            readDevices: readDevices
        )
        self.deviceSnapshotTTLNanoseconds = deviceSnapshotTTLNanoseconds
        self.deviceSnapshotClock = deviceSnapshotClock
        self.deviceSnapshotDeadlineNanoseconds = deviceSnapshotDeadlineNanoseconds
        self.deviceSnapshotSleep = deviceSnapshotSleep
        self.bootedUDIDsOverride = nil
    }

    // MARK: - Listing

    /// Every device CoreSimulator knows about. Throws if the bridge
    /// can't enumerate, e.g. CoreSimulator isn't loadable on the
    /// host. Used to back `device.list({scope: "all"})`.
    public func listAll() async throws -> [CSBDeviceInfo] {
        switch await deviceRead() {
        case let .completed(.success(devices)):
            return devices

        case let .completed(.failure(failure)):
            throw DeviceError.listFailed(message: failure.message)

        case .timedOut:
            throw DeviceError.listTimedOut
        }
    }

    /// Subset of `listAll()` filtered to the sims deviceterm currently
    /// considers itself the owner of. The filter intersects ownership with
    /// the shared CoreSimulator snapshot, so ownership entries absent from
    /// that snapshot drop out.
    public func listOwned() async throws -> [CSBDeviceInfo] {
        guard !ownership.isEmpty else { return [] }
        let all = try await listAll()
        return all.filter { owns($0.udid.lowercased()) }
    }

    /// Number of owned sims currently in the `Booted` state.
    /// Distinct from `ownedCount` (raw map size): a sim shut down
    /// externally (Simulator.app, `simctl shutdown`, crash) leaves
    /// a stale ownership record until something else clears it,
    /// and using the map size for status-item visibility or idle-
    /// exit liveness would lie. Falls back to 0 on bridge failure:
    /// a degraded CoreSimulator means we can't confirm liveness, so
    /// the daemon's "I'm alive holding sims" signal hides rather
    /// than asserting something we can't verify.
    /// When the ownership map is empty, returns 0 without consulting
    /// CoreSimulator: no live device can intersect an empty owned set.
    public func ownedBootedCount() async -> Int {
        guard !ownership.isEmpty else { return 0 }
        let devices: [CSBDeviceInfo]
        do {
            devices = try await listOwned()
        } catch {
            return 0
        }
        return devices.filter { $0.state == .booted }.count
    }

    /// Owned sims currently in the `Booted` state, as plain `Sendable`
    /// snapshots for the status-item menu. The status item takes one of
    /// these per poll tick and derives *both* its badge visibility and
    /// count and its shutdown menu (`statusMenuEntries`) from the same
    /// snapshot, so the two can never disagree across separate
    /// CoreSimulator reads. Throws on bridge failure so RPC callers can
    /// distinguish an incomplete roster from an authoritative empty one;
    /// status-item callers explicitly retain the degraded `[]` fallback.
    /// When the ownership map is empty, returns `[]` without consulting
    /// CoreSimulator, since no live device can intersect an empty owned set.
    public func listOwnedBooted() async throws -> [OwnedSim] {
        guard !ownership.isEmpty else { return [] }
        let devices = try await listOwned()
        return devices
            .filter { $0.state == .booted }
            .map { OwnedSim(
                udid: $0.udid,
                name: $0.name,
                runtimeIdentifier: $0.runtimeIdentifier,
                sessionId: owner(of: $0.udid.lowercased())
            )
            }
    }

    /// Session that owns `udid`, if any. Used to populate the
    /// `ownedBySession` field on the wire when a caller asks for the
    /// "all" scope.
    public func ownerSession(forUDID udid: String) -> UUID? {
        owner(of: udid.lowercased())
    }

    /// Whether `udid` is `Booted` in the shared CoreSimulator snapshot,
    /// independent of ownership. The shutdown-convergence path invalidates the
    /// snapshot before attempting shutdown, so its post-error check enumerates
    /// again. That check distinguishes "already gone" (mark its panes shut
    /// down) from "still up" (leave the pane live). Returns `false` if the
    /// bridge can't enumerate: a degraded CoreSimulator can't confirm liveness,
    /// so we don't assert the sim is still running.
    public func isBooted(udid: String) async -> Bool {
        do {
            return try await bootedUDIDs()?.contains(udid.lowercased()) ?? false
        } catch {
            return false
        }
    }

    /// One cached device-set answer. Cache state stays on this actor so a
    /// commanded or observed transition can invalidate it synchronously with
    /// the corresponding ownership mutation. Only the blocking bridge read is
    /// handed to `CoreSimulatorDeviceReader`'s serial DispatchQueue.
    private func deviceRead() async -> DeviceReadResult {
        while true {
            let now = deviceSnapshotClock()
            if let cachedDeviceRead,
                now >= cachedDeviceRead.completedAtNanoseconds,
                now - cachedDeviceRead.completedAtNanoseconds < deviceSnapshotTTLNanoseconds {
                return .completed(cachedDeviceRead.result)
            }
            cachedDeviceRead = nil

            if inFlightDeviceRead == nil {
                startDeviceRead(generation: deviceSnapshotGeneration)
            }

            switch await waitForDeviceRead() {
            case let .completed(result, generation):
                guard deviceSnapshotGeneration == generation else { continue }
                return .completed(result)

            case .retry:
                continue

            case .timedOut:
                return .timedOut
            }
        }
    }

    /// Begin one raw bridge read. Its task is deliberately unstructured: a
    /// caller timing out or disconnecting cannot cancel CoreSimulator's
    /// synchronous `SimDeviceSet.devices` call, so an independent supervisor
    /// owns its eventual completion and accounts for its result.
    private func startDeviceRead(generation: UInt64) {
        let token = UUID()
        let startedAtNanoseconds = deviceSnapshotClock()
        let reader = deviceReader
        let task = Task { await reader.read() }
        let deadlineNanoseconds = deviceSnapshotDeadlineNanoseconds
        let sleep = deviceSnapshotSleep
        let timeoutTask = Task { [weak self] in
            do {
                try await sleep(deadlineNanoseconds)
            } catch {
                return
            }
            await self?.timeOutDeviceRead(token: token)
        }
        inFlightDeviceRead = InFlightDeviceRead(
            token: token,
            generation: generation,
            startedAtNanoseconds: startedAtNanoseconds,
            task: task,
            timeoutTask: timeoutTask,
            waiters: [],
            timedOut: false
        )
        DiagnosticLog.attach.debug(
            "CoreSimulator device enumeration started; generation \(generation, privacy: .public)"
        )
        Task { [weak self] in
            let result = await task.value
            await self?.completeDeviceRead(
                token: token,
                generation: generation,
                result: result
            )
        }
    }

    private func waitForDeviceRead() async -> DeviceReadWaitResult {
        await withCheckedContinuation { continuation in
            guard var inFlightDeviceRead else {
                continuation.resume(returning: .retry)
                return
            }
            guard !inFlightDeviceRead.timedOut else {
                continuation.resume(returning: .timedOut)
                return
            }
            inFlightDeviceRead.waiters.append(continuation)
            self.inFlightDeviceRead = inFlightDeviceRead
        }
    }

    private func timeOutDeviceRead(token: UUID) {
        guard var inFlightDeviceRead,
            inFlightDeviceRead.token == token,
            !inFlightDeviceRead.timedOut else { return }
        let waiters = inFlightDeviceRead.waiters
        inFlightDeviceRead.waiters = []
        inFlightDeviceRead.timedOut = true
        self.inFlightDeviceRead = inFlightDeviceRead
        let deadlineMilliseconds = deviceSnapshotDeadlineNanoseconds / 1_000_000
        DiagnosticLog.attach.error(
            """
            CoreSimulator device enumeration timed out after \
            \(deadlineMilliseconds, privacy: .public)ms; circuit open
            """
        )
        for waiter in waiters {
            waiter.resume(returning: .timedOut)
        }
    }

    private func completeDeviceRead(
        token: UUID,
        generation: UInt64,
        result: CoreSimulatorDeviceReadResult
    ) {
        guard let inFlightDeviceRead, inFlightDeviceRead.token == token else { return }
        inFlightDeviceRead.timeoutTask.cancel()
        self.inFlightDeviceRead = nil

        let isCurrent = deviceSnapshotGeneration == generation
        if isCurrent {
            cachedDeviceRead = CachedDeviceRead(
                result: result,
                completedAtNanoseconds: deviceSnapshotClock()
            )
        }

        let elapsedMilliseconds = elapsedNanoseconds(
            since: inFlightDeviceRead.startedAtNanoseconds
        ) / 1_000_000
        if inFlightDeviceRead.timedOut {
            let disposition = isCurrent ? "cached" : "discarded after invalidation"
            DiagnosticLog.attach.notice(
                """
                CoreSimulator device enumeration returned after timeout in \
                \(elapsedMilliseconds, privacy: .public)ms; \
                \(disposition, privacy: .public)
                """
            )
        } else {
            DiagnosticLog.attach.debug(
                """
                CoreSimulator device enumeration completed in \
                \(elapsedMilliseconds, privacy: .public)ms; \
                generation \(generation, privacy: .public)
                """
            )
        }

        for waiter in inFlightDeviceRead.waiters {
            waiter.resume(returning: .completed(result, generation: generation))
        }
    }

    private func elapsedNanoseconds(since start: UInt64) -> UInt64 {
        let now = deviceSnapshotClock()
        return now >= start ? now - start : 0
    }

    /// Production derives boot state from the same snapshot as `listAll()`.
    /// The override exists only for hermetic ownership-restoration fixtures.
    /// A completed bridge failure remains "can't confirm" (`nil`), while a
    /// timeout throws: restoration callers must retry a read CoreSimulator has
    /// not answered rather than treating it as an authoritative empty set.
    private func bootedUDIDs() async throws -> Set<String>? {
        if let bootedUDIDsOverride { return bootedUDIDsOverride() }
        switch await deviceRead() {
        case let .completed(.success(devices)):
            return Set(
                devices
                    .filter { $0.state == .booted }
                    .map { $0.udid.lowercased() }
            )

        case .completed(.failure):
            return nil

        case .timedOut:
            throw DeviceError.listTimedOut
        }
    }

    private func invalidateDeviceSnapshot() {
        deviceSnapshotGeneration &+= 1
        cachedDeviceRead = nil
    }

    // MARK: - Lifecycle

    /// Boot a device by UDID. Returns when CoreSimulator has accepted
    /// the boot *intent* (not when SpringBoard has rendered, which is
    /// `SimDisplayHandle`'s job, and is observed via the pane's
    /// `surface.changed` events once that chunk lands).
    ///
    /// Attribution is separate: a pending claim promotes only after the
    /// notifier or shared device snapshot reports `Booted`.
    public func boot(udid: String, activatingClaimAttemptId: String? = nil) throws {
        let normalized = try requireValidUDID(udid)
        let claimAttemptId = activatingClaimAttemptId.flatMap(UUID.init(uuidString:))
        let handle: SimDeviceHandle
        do {
            handle = try SimDeviceHandle.handle(forUDID: normalized)
        } catch {
            failPreparedBootClaim(claimAttemptId)
            throw DeviceError.notFound(udid: normalized)
        }
        do {
            try handle.boot()
        } catch {
            failPreparedBootClaim(claimAttemptId)
            throw DeviceError.bootFailed(
                udid: normalized,
                message: String(describing: error)
            )
        }
        invalidateDeviceSnapshot()
        if let claimAttemptId {
            activateBootClaim(claimAttemptId)
        }
    }

    /// Shut down a device by UDID. The CoreSimulator call is
    /// synchronous; on success we drop any ownership record for the
    /// sim, since a shut-down sim isn't owned by anyone (its UDID can be
    /// freely re-booted by a different session later).
    public func shutdown(udid: String) async throws {
        let normalized = try requireValidUDID(udid)
        // Invalidate before either bridge operation can fail. The converged
        // shutdown path checks `isBooted` after any error, and that correctness
        // check must enumerate after the attempted shutdown rather than reuse a
        // pre-attempt success or failure.
        invalidateDeviceSnapshot()
        let handle: SimDeviceHandle
        do {
            handle = try SimDeviceHandle.handle(forUDID: normalized)
        } catch {
            throw DeviceError.notFound(udid: normalized)
        }
        do {
            try handle.shutdown()
        } catch {
            throw DeviceError.shutdownFailed(
                udid: normalized,
                message: String(describing: error)
            )
        }
        ownership.removeValue(forKey: normalized)
        cancelBootClaim(forUDID: normalized)
        // Publish device.shutdown. Symmetric with boot: debounced
        // against a same-UDID notification arrival.
        await publishShutdown(udid: normalized)
    }

    // MARK: - Ownership manipulation (for shim events + tests)

    /// Reconcile one causally bounded DeviceTerm boot attempt. Registering the
    /// claim never asserts that the simulator is already booted. Promotion is
    /// gated on the shared CoreSimulator snapshot or its notifier.
    public func reconcileBootClaim(
        _ evidence: BootClaimEvidence,
        sessionId: UUID?,
        currentIncarnation: UInt64? = nil,
        inspectCurrentState: Bool = true,
        activateImmediately: Bool = true
    ) async throws -> DeviceReconcileBootClaimResult {
        guard let attemptId = UUID(uuidString: evidence.attemptId) else {
            throw DeviceError.malformedUDID(udid: evidence.attemptId)
        }
        let normalized = try requireValidUDID(evidence.udid)
        let now = deviceSnapshotClock()
        expireBootClaims(now: now)
        var effectiveSessionId = evidence.disposition == .attach ? sessionId : nil
        var effectiveDisposition = evidence.disposition
        // A claim naming a closed session takes that session's recorded
        // verdict, followed through any chain of promotions: A handed to B, B
        // later handed to C, and a claim for A landing inside the lease has
        // to reach C. A terminal link stops the chain. A later promotion
        // must not resurrect a device its own tab already gave up.
        //
        // `currentIncarnation` is the claim session's live incarnation as the
        // handler resolved it. A session live at a NEWER incarnation than the
        // tombstone's has been restored since the close, and its fresh claims
        // are its own; without the comparison the old tombstone would
        // disposition them for the rest of its lease.
        if let sessionId, let closed = closedBootSessions[sessionId],
            closed.expiresAtNanoseconds > now,
            tombstoneApplies(closed, currentIncarnation: currentIncarnation) {
            let resolved = resolvedCloseOutcome(from: sessionId, at: now)
            effectiveSessionId = resolved.successor.flatMap { UUID(uuidString: $0) }
            effectiveDisposition = effectiveSessionId == nil
                ? terminalDisposition(for: resolved)
                : .attach
        }
        let submittedEvidence = BootClaimEvidence(
            attemptId: evidence.attemptId,
            udid: normalized,
            source: evidence.source,
            observedState: evidence.observedState,
            disposition: effectiveDisposition,
            remainingLeaseMilliseconds: evidence.remainingLeaseMilliseconds
        )

        if var existing = bootClaims[attemptId] {
            guard existing.evidence.udid.caseInsensitiveCompare(normalized) == .orderedSame else {
                return bootClaimResult(attemptId: attemptId, record: existing, status: .failed)
            }
            if existing.status == .pending {
                existing.evidence = BootClaimEvidence(
                    attemptId: existing.evidence.attemptId,
                    udid: normalized,
                    source: existing.evidence.source,
                    observedState: strongest(
                        existing.evidence.observedState,
                        submittedEvidence.observedState
                    ),
                    disposition: submittedEvidence.disposition,
                    remainingLeaseMilliseconds: submittedEvidence.remainingLeaseMilliseconds
                )
                existing.sessionId = effectiveSessionId
                bootClaims[attemptId] = existing
            }
        } else {
            let lease = min(
                submittedEvidence.remainingLeaseMilliseconds,
                BootClaimEvidence.maximumLeaseMilliseconds
            )
            guard lease > 0 else {
                let record = BootClaimRecord(
                    evidence: submittedEvidence,
                    sessionId: effectiveSessionId,
                    expiresAtNanoseconds: now,
                    status: .expired
                )
                bootClaims[attemptId] = record
                return bootClaimResult(attemptId: attemptId, record: record)
            }
            let duration = lease.multipliedReportingOverflow(by: 1_000_000)
            let deadline = now.addingReportingOverflow(duration.partialValue)
            guard !duration.overflow, !deadline.overflow else {
                throw DeviceError.malformedUDID(udid: evidence.attemptId)
            }
            let record = BootClaimRecord(
                evidence: BootClaimEvidence(
                    attemptId: submittedEvidence.attemptId,
                    udid: normalized,
                    source: submittedEvidence.source,
                    observedState: submittedEvidence.observedState,
                    disposition: submittedEvidence.disposition,
                    remainingLeaseMilliseconds: lease
                ),
                sessionId: effectiveSessionId,
                expiresAtNanoseconds: deadline.partialValue,
                status: .pending
            )
            bootClaims[attemptId] = record
            if activateImmediately {
                activateBootClaim(attemptId)
            }
        }

        if inspectCurrentState, await isBooted(udid: normalized) {
            _ = await promoteBootClaim(attemptId: attemptId)
        }
        if inspectCurrentState { ensureBootClaimPoller() }
        guard let settled = bootClaims[attemptId] else {
            return DeviceReconcileBootClaimResult(
                attemptId: evidence.attemptId,
                udid: normalized,
                status: .failed,
                sessionId: nil
            )
        }
        return bootClaimResult(attemptId: attemptId, record: settled)
    }

    /// Apply the terminal's close choice before its session is removed,
    /// without a cohort verdict in front of it: the compatibility arm, and
    /// the fallback when incarnation resolution races session removal.
    public func noteSessionClosing(_ sessionId: UUID, mode: PaneCloseMode) async {
        await applyCohortEffect(
            .close(
                CohortCloseEffect(
                    sessionId: sessionId,
                    incarnation: nil,
                    outcome: mode == .shutdown ? .shutdown : .detach
                )
            )
        )
    }

    /// Apply one cohort device effect, delivered by the effect pump in the
    /// order the cohort transitions committed.
    func applyCohortEffect(_ effect: CohortDeviceEffect) async {
        switch effect {
        case let .close(close):
            await applyClose(close)

        case let .transfer(transfer):
            applyTransfer(transfer)
        }
    }

    /// A genuine session close. Records the tombstone, then converges the
    /// session's claims and ownership on the verdict.
    ///
    /// The pump delivers this asynchronously to the close that decided it, so
    /// the convergence is deliberate: a Booted notification that promotes an
    /// attach claim between the verdict and this application is swept here,
    /// re-homed to the successor or dispositioned, exactly as one that
    /// promoted before the close.
    ///
    /// On a promotion, every ownership entry the member holds moves to the
    /// successor together with its claims. The tab is still open and only
    /// one of its terminals left, so taking the detach or shutdown arm would
    /// kill a simulator the tab still wants, or strand it attributed to
    /// nobody. A terminal verdict touches ownership only through the
    /// session's promoted claims; everything else it owned stays for GUI
    /// recovery.
    private func applyClose(_ close: CohortCloseEffect) async {
        let now = deviceSnapshotClock()
        expireBootClaims(now: now)
        let deadline = now.addingReportingOverflow(
            BootClaimEvidence.maximumLeaseMilliseconds * 1_000_000
        )
        closedBootSessions[close.sessionId] = ClosedBootSession(
            outcome: close.outcome,
            incarnation: close.incarnation,
            expiresAtNanoseconds: deadline.overflow ? UInt64.max : deadline.partialValue
        )
        ensureClosedBootSessionCleaner()
        let successor = close.outcome.successor.flatMap { UUID(uuidString: $0) }
        var promotedShutdowns: Set<String> = []
        for attemptId in Array(bootClaims.keys) {
            guard var record = bootClaims[attemptId], record.sessionId == close.sessionId,
                record.status == .pending || record.status == .promoted else { continue }
            // A promotion keeps the claim attached, re-homed on the
            // successor; a terminal verdict clears the claim's session and
            // stamps the terminal disposition.
            record.sessionId = successor
            record.evidence = BootClaimEvidence(
                attemptId: record.evidence.attemptId,
                udid: record.evidence.udid,
                source: record.evidence.source,
                observedState: record.evidence.observedState,
                disposition: successor == nil ? terminalDisposition(for: close.outcome) : .attach,
                remainingLeaseMilliseconds: record.evidence.remainingLeaseMilliseconds
            )
            bootClaims[attemptId] = record
            guard record.status == .promoted, owns(record.evidence.udid),
                owner(of: record.evidence.udid) == close.sessionId else { continue }
            if let successor {
                ownership[record.evidence.udid] = successor
            } else if case .shutdown = close.outcome {
                promotedShutdowns.insert(record.evidence.udid)
            } else {
                ownership[record.evidence.udid] = UUID?.none
            }
        }
        // Simulators the session owned without a converging claim change
        // hands too, or a tab that keeps its device loses the attribution its
        // close prompts and `device.list` read from.
        if let successor {
            for (udid, owner) in ownership where owner == close.sessionId {
                ownership[udid] = successor
            }
            invalidateDeviceSnapshot()
        }
        for udid in promotedShutdowns {
            try? await shutdown(udid: udid)
        }
    }

    /// A targeted transfer: a reconcile dropped a still-live member, so only
    /// the named devices and their matching claims move. No tombstone and no
    /// wider sweep. The session is alive, and its unrelated devices and late
    /// claims stay its own.
    ///
    /// **Accepted race.** A matching claim issued by the dropped member
    /// before the transfer but delivered after it stays attributed to that
    /// member and can promote ownership of the same udid back, against the
    /// committed transfer. This needs all three of: a cohort replacement
    /// dropping a live pane owner, a matching claim concurrently in flight,
    /// and delivery after the transfer. The consequence is not confined to
    /// attribution: if the dropped member later closes, its regained
    /// ownership takes that close's disposition, so the transferred
    /// simulator can be detached or shut down out from under the cohort that
    /// holds its pane. An ordinary same-cohort reconcile does not repair it
    /// (no member is newly removed, so no transfer is emitted); only another
    /// ownership-changing attach or transfer does. Closing it properly needs
    /// causal identity on the claim wire, a topology generation or similar,
    /// so a pre-transfer claim redirects to the successor while a genuinely
    /// new claim wins. A lease-wide `(owner, udid)` redirect cannot express
    /// that: it would misdirect new intent for the whole lease to close a
    /// narrower window.
    private func applyTransfer(_ transfer: CohortTransferEffect) {
        let udids = Set(
            transfer.targets.compactMap { target -> String? in
                guard case let .sim(udid) = target else { return nil }
                return udid.lowercased()
            }
        )
        guard !udids.isEmpty else { return }
        var moved = false
        for udid in udids where owner(of: udid) == transfer.previousOwner.sessionId {
            ownership[udid] = transfer.successor.sessionId
            moved = true
        }
        for attemptId in Array(bootClaims.keys) {
            guard var record = bootClaims[attemptId],
                record.sessionId == transfer.previousOwner.sessionId,
                udids.contains(record.evidence.udid.lowercased()),
                record.status == .pending || record.status == .promoted else { continue }
            record.sessionId = transfer.successor.sessionId
            bootClaims[attemptId] = record
        }
        if moved { invalidateDeviceSnapshot() }
    }

    /// Whether a tombstone still governs claims naming its session: yes,
    /// unless the session is live at a newer incarnation than the one the
    /// verdict was recorded for. A tombstone recorded without one (the
    /// compatibility arm) applies unconditionally.
    private func tombstoneApplies(
        _ closed: ClosedBootSession,
        currentIncarnation: UInt64?
    ) -> Bool {
        guard let recorded = closed.incarnation, let current = currentIncarnation else {
            return true
        }
        return current <= recorded
    }

    /// Follow a closed session's verdict through any promotion chain.
    ///
    /// Path-compresses what it walks, so a long chain costs one hop next
    /// time, and is cycle-protected: two records pointing at each other must
    /// answer, not hang the reconcile path. A successor with no tombstone of
    /// its own is still live, and the walk ends there.
    private func resolvedCloseOutcome(from sessionId: UUID, at now: UInt64) -> CohortCloseOutcome {
        guard var current = closedBootSessions[sessionId]?.outcome else { return .detach }
        var visited: Set<UUID> = [sessionId]
        var walked: [UUID] = [sessionId]
        while case let .promote(successor) = current {
            guard let successorId = UUID(uuidString: successor),
                let next = closedBootSessions[successorId],
                next.expiresAtNanoseconds > now else { break }
            guard visited.insert(successorId).inserted else { break }
            walked.append(successorId)
            current = next.outcome
        }
        for id in walked {
            guard let existing = closedBootSessions[id] else { continue }
            closedBootSessions[id] = ClosedBootSession(
                outcome: current,
                incarnation: existing.incarnation,
                expiresAtNanoseconds: existing.expiresAtNanoseconds
            )
        }
        return current
    }

    /// The boot-claim disposition a terminal outcome reduces to. Callers
    /// branch on the promotion case first; a promoted claim stays `.attach`.
    private func terminalDisposition(for outcome: CohortCloseOutcome) -> BootClaimDisposition {
        switch outcome {
        case .promote:
            return .attach

        case .detach:
            return .detach

        case .shutdown:
            return .shutdown
        }
    }

    /// Transfer an already-Booted simulator into a session without fabricating
    /// a lifecycle transition. Used by `device.attach`.
    public func transferOwnership(udid: String, sessionId: UUID) throws {
        let normalized = try requireValidUDID(udid)
        invalidateDeviceSnapshot()
        ownership[normalized] = sessionId
    }

    /// MIGRATION: Accepts claimless shim.event boots during mixed-version
    /// bundle replacement and for test setup. Claim-bearing events use
    /// `reconcileBootClaim`.
    /// Idempotent: repeat calls for the same UDID overwrite the
    /// owning session (last writer wins, matches the GUI's
    /// "Already attached in tab X. Move? [y/n]" semantics).
    ///
    /// Publishes `device.booted` because the compatibility call represents a
    /// completed boot. Current shims use `reconcileBootClaim` instead, which
    /// waits for CoreSimulator to report Booted before publishing.
    public func recordOwnership(udid: String, sessionId: UUID) async throws {
        let normalized = try requireValidUDID(udid)
        invalidateDeviceSnapshot()
        ownership[normalized] = sessionId
        // Shim sent us one boot event; publish regardless of prior
        // ownership state. A re-record (session B claiming session
        // A's previously-owned UDID) corresponds to a fresh shim-
        // intercepted boot and is a real `device.booted` event. The
        // debounce window suppresses a follow-up CoreSimulator
        // notification for the same UDID landing milliseconds later.
        await publishBoot(udid: normalized)
    }

    /// Restore ownership claims for already-booted sims, for a daemon that
    /// came back holding nothing. Returns the normalized udids whose requested
    /// ownership and attribution now match, a subset of what was asked for.
    ///
    /// Nothing is booted and no `device.booted` event is published: no sim
    /// changed state, and a subscriber told otherwise would see a boot that
    /// never happened. This is bookkeeping catching up with reality, not a
    /// transition.
    ///
    /// Two refusals, both silent, because neither is the caller's fault:
    ///
    ///   - A udid this daemon ALREADY owns keeps its existing attribution,
    ///     including an unattributed one. The live map is newer than any mirror
    ///     a caller can hold, so a re-assertion fills gaps rather than arguing;
    ///     asking for the attribution it already has still counts as restored,
    ///     so a retry is idempotent.
    ///   - A udid CoreSimulator does not currently report as Booted is not
    ///     claimed at all. A sim that shut down while nobody was watching is
    ///     gone, and claiming it would put a device deviceterm no longer owns
    ///     back into the shut-down prompts.
    ///
    /// The booted set is read ONCE for the whole batch rather than per udid,
    /// and gates what is REPORTED as well as what is written. An attribution
    /// this daemon already holds can be stale (nothing disowns a sim that shut
    /// down until the notifier says so), so reporting it without checking
    /// would answer "restored" for a sim that is gone.
    ///
    /// A completed bridge failure reports nothing, matching the rest of this
    /// actor's "a degraded CoreSimulator asserts nothing" posture. A timed-out
    /// read throws instead: CoreSimulator has not answered yet, so the GUI's
    /// bounded ownership-restoration retry window must remain open.
    public func restoreOwnership(_ claims: [String: UUID?]) async throws -> OwnershipRestoreResult {
        guard !claims.isEmpty else {
            return OwnershipRestoreResult(attributed: [], written: [:])
        }
        guard let booted = try await bootedUDIDs() else {
            return OwnershipRestoreResult(attributed: [], written: [:])
        }
        var attributed: Set<String> = []
        var written: [String: UUID?] = [:]
        for (udid, sessionId) in claims {
            let normalized = udid.lowercased()
            guard booted.contains(normalized) else { continue }
            if owns(normalized) {
                // Ownership already recorded. Report it only when the
                // attribution agrees, including nil against nil, so a retry is
                // idempotent while a disagreement loses to what is already here.
                if owner(of: normalized) == sessionId { attributed.insert(normalized) }
                continue
            }
            ownership[normalized] = sessionId
            attributed.insert(normalized)
            written[normalized] = sessionId
        }
        return OwnershipRestoreResult(attributed: attributed, written: written)
    }

    /// Drop the attribution from ownership entries whose session has since
    /// gone, keeping the ownership itself.
    ///
    /// Demoting rather than removing, because a session ending is not a sim
    /// ending: that is the state closing a tab with Detach leaves behind, and
    /// the status item lists it under "Unlinked". Removing the entry would
    /// instead leave a running sim nothing claims, so nothing offers to shut
    /// it down.
    ///
    /// The one caller is `device.restoreOwnership`, for a claim whose named
    /// session it could not confirm live.
    ///
    /// Compare-and-set: an entry moves only while the recorded owner is still
    /// the session named, so an attribution something else has made for the
    /// same sim since survives. Publishes nothing; no sim changed state.
    public func demoteOwnership(_ entries: [String: UUID]) {
        for (udid, sessionId) in entries {
            let normalized = udid.lowercased()
            guard owns(normalized), owner(of: normalized) == sessionId else { continue }
            ownership[normalized] = UUID?.none
        }
    }

    /// Drop the ownership record for `udid` without affecting the
    /// sim itself. Reached by the shim's shutdown event.
    ///
    /// Publishes `device.shutdown` here for the shim-shutdown path.
    /// Symmetric with `recordOwnership` and covers the in-tab
    /// `xcrun simctl shutdown <UDID>` workflow.
    public func releaseOwnership(udid: String) async {
        let normalized = udid.lowercased()
        invalidateDeviceSnapshot()
        ownership.removeValue(forKey: normalized)
        cancelBootClaim(forUDID: normalized)
        // The shim told us this UDID has shut down. Publish even if
        // our ownership map didn't have a record (the shim's view
        // of reality is the truth here). Debounced against a
        // CoreSimulator notification arriving for the same UDID.
        await publishShutdown(udid: normalized)
    }

    /// Remove every ownership record attributed to a session in `sessionIds`,
    /// leaving unattributed entries alone.
    public func releaseOwnership(for sessionIds: Set<UUID>) {
        ownership = ownership.filter { entry in
            guard let attributed = entry.value else { return true }
            return !sessionIds.contains(attributed)
        }
    }

    // MARK: - CoreSimulator notification subscription
    //
    // Set-level subscription via `CSBDeviceNotifier`. Catches every
    // sim state transition regardless of who initiated it: shim-
    // intercepted `simctl boot`, xcodebuild's destination boot,
    // absolute-path `/usr/bin/xcrun simctl boot`, FFI callers
    // bypassing xcrun entirely, Simulator.app's File → Open Device,
    // and sims booted before the daemon started. Without this,
    // deviceterm's view of "what's running" depends on whether the
    // shim happened to be on the boot caller's PATH, which the
    // watchOS game-dev `./sim run` workflow showed is unreliable
    // for callers that bypass deviceterm's bin shim entirely.

    /// Install the notification subscription. Idempotent: calling
    /// twice without unsubscribing in between leaves the existing
    /// subscription in place and returns. Throws only on bridge-
    /// load failure (CoreSimulator unavailable, registration
    /// returned 0); callers that hit those should log + degrade
    /// gracefully (no notifications, but claim reconciliation's bounded
    /// state polling still converges DeviceTerm-originated boots).
    ///
    /// Shape: the ObjC handler yields to an `AsyncStream`, and a
    /// long-lived consumer task loops `for await arrival in stream`,
    /// calling the actor-isolated handler. The `DispatchQueue`
    /// passed to the bridge is an unavoidable CoreSimulator
    /// requirement (the private API takes a `dispatch_queue_t`);
    /// CoreSimulator retains it for the registration's lifetime so
    /// the local scope here is sound.
    ///
    /// `paneShutdownConverger` is a parameter rather than a settable
    /// property so the notifier cannot be installed without pane-shutdown
    /// handling. An observed shutdown that doesn't reach the pane registry
    /// leaves the pane frozen on its last frame with no Reboot/Close
    /// affordance.
    public func subscribeToCoreSimulator(
        paneShutdownConverger: @escaping @Sendable (String) async -> Void
    ) throws {
        if notifier != nil { return }
        let (stream, continuation) = AsyncStream<NotifierArrival>.makeStream()
        let queue = DispatchQueue(
            label: "com.deviceterm.daemon.devicenotifier",
            qos: .userInitiated
        )
        let notifier = try CSBDeviceNotifier.defaultNotifier(queue: queue) { event in
            // Stamped on CoreSimulator's callback queue, the only place
            // that knows when the notification arrived. The consumer below
            // handles events one at a time and a handler can run long, so a
            // queued event's own `Date()` can sit far from the transition it
            // describes.
            continuation.yield(NotifierArrival(event: event, arrivedAt: Date()))
        }
        // Installed only once registration succeeded, so a bridge-load
        // failure leaves no converger behind a notifier that never exists.
        self.paneShutdownConverger = paneShutdownConverger
        self.notifier = notifier
        self.notifierContinuation = continuation
        self.notifierConsumer = Task { [weak self] in
            for await arrival in stream {
                await self?.handleNotifierEvent(arrival)
            }
        }
    }

    /// Drop the subscription. Idempotent. Called on daemon
    /// shutdown so CoreSimulator doesn't retain a callback into
    /// the (about-to-disappear) actor. Order: cancel the bridge
    /// registration first (CoreSimulator stops dispatching to the
    /// block), then finish the stream so the consumer task exits
    /// cleanly. The consumer task isn't `cancel()`-ed because the
    /// `for await` loop ends naturally when the stream finishes, since
    /// cancelling would race the bridge handler's last yield.
    public func unsubscribeFromCoreSimulator() {
        notifier?.cancel()
        notifier = nil
        notifierContinuation?.finish()
        notifierContinuation = nil
        notifierConsumer = nil
        paneShutdownConverger = nil
    }

    /// Dispatch a notification arriving from CoreSimulator into
    /// the right state mutation. The notifier wrapper only
    /// surfaces `.stateChanged` events with a populated UDID;
    /// `.other` and empty-UDID events drop here without effect.
    func handleNotifierEvent(_ arrival: NotifierArrival) async {
        let event = arrival.event
        guard event.kind == .stateChanged, !event.udid.isEmpty else { return }
        switch event.newState {
        case .booted:
            await noteObservedBoot(udid: event.udid, arrivedAt: arrival.arrivedAt)

        case .shutdown:
            await noteExternalShutdown(udid: event.udid, arrivedAt: arrival.arrivedAt)

        case .unknown, .creating, .booting, .shuttingDown:
            invalidateDeviceSnapshot()
            // Intermediate states aren't actionable: the daemon's
            // wire model only emits `.booted` / `.shutdown`. A
            // sim that stalls in `.booting` is observed as
            // "still booting" via the discovery poll; no need
            // to invent a new event type for it.

        @unknown default:
            invalidateDeviceSnapshot()
        }
    }

    /// External-boot path: the notification said a UDID entered
    /// `.booted` without a live causal claim. Publish the event so
    /// subscribers see the boot;
    /// don't record ownership (the sim has no attributed session,
    /// matching the linkage-model's "external sims stay unattached"
    /// property, though the user can claim it via `deviceterm pane attach`).
    /// `arrivedAt` defaults to now for direct callers; the notifier passes
    /// the delivery timestamp. A boot queued behind a slow shutdown handler
    /// would otherwise be timed from when it got a turn.
    func noteExternalBoot(udid: String, arrivedAt: Date = Date()) async {
        let normalized = udid.lowercased()
        invalidateDeviceSnapshot()
        await publishBootDebounced(udid: normalized, arrivedAt: arrivedAt)
    }

    /// Reconcile a CoreSimulator Booted observation with a pending causal
    /// claim. A claim that expired or otherwise cannot promote must not consume
    /// the lifecycle event: it falls through as an external, unowned boot.
    func noteObservedBoot(udid: String, arrivedAt: Date = Date()) async {
        let normalized = udid.lowercased()
        invalidateDeviceSnapshot()
        if let attemptId = activeBootClaimByUDID[normalized],
            await promoteBootClaim(attemptId: attemptId) {
            return
        }
        await noteExternalBoot(udid: normalized, arrivedAt: arrivedAt)
    }

    /// External-shutdown path: a UDID transitioned to `.shutdown`.
    /// Drop any ownership record (the sim is gone regardless of
    /// who shut it down) and publish, debounced against a
    /// concurrent shim shutdown event for the same UDID.
    ///
    /// Also converges any pane attached to that UDID. This is the
    /// fourth shutdown surface, and the only one that catches a sim
    /// killed by something outside deviceterm entirely: quitting
    /// Simulator.app (which shuts down the devices it attached to), a
    /// `simctl shutdown` from an unshimmed shell, or a crash. Without
    /// it the sim's frames simply stop arriving and the pane sits on
    /// its last frame with live-looking controls that no longer do
    /// anything. Convergence is idempotent, so a shutdown deviceterm
    /// itself initiated (already converged by its own path) costs a
    /// no-op here.
    /// `arrivedAt` carries the notification's true arrival instant; see
    /// `NotifierArrival`. It defaults to now for direct callers.
    func noteExternalShutdown(udid: String, arrivedAt: Date = Date()) async {
        let normalized = udid.lowercased()
        invalidateDeviceSnapshot()
        ownership.removeValue(forKey: normalized)
        cancelBootClaim(forUDID: normalized)
        // Settle the debounce against `arrivedAt` before converging: both
        // the window comparison and the recorded stamp. Backend teardown is
        // unbounded and holds the serial consumer, so a queued duplicate
        // doesn't start until it finishes; timing either half from
        // processing would let that duplicate escape the window.
        let shouldPublish = admitNotificationShutdown(udid: normalized, arrivedAt: arrivedAt)
        // Publish first, matching the commanded path in
        // `DeviceMethods.shutdownConverged`. Convergence suspends this actor
        // and exposes the shutdown elsewhere: retiring a pane yields
        // `.stateChanged(.shutdown)` to its subscribers and puts a Reboot
        // affordance in front of the user. Anything that reacts by booting
        // publishes while this call is still suspended, so a boot event
        // would precede the shutdown that caused it.
        if shouldPublish {
            await eventBroker?.publish(.deviceShutdown(udid: normalized), to: .everyone)
        }
        await paneShutdownConverger?(normalized)
    }

    // MARK: - Publish debounce
    //
    // Two sources converge here: the AUTHORITATIVE path (a promoted boot
    // claim, a compatibility `recordOwnership`, or a shutdown request/event)
    // and the NOTIFICATION path (CoreSimulator's device-set notifier). Each
    // source is debounced ONLY against the OTHER source within
    // `debounceWindow`. Two consecutive authoritative publishes are distinct
    // real events and both fire; a notification that arrives shortly after an
    // authoritative publish for the same transition is suppressed.
    //
    // The notification path also debounces against itself, so a
    // duplicate notification (rare) doesn't double-emit.

    /// Authoritative `deviceBooted` publish, used by promoted claims and the
    /// compatibility `recordOwnership()`. Skipped only when the notification
    /// path fired for the same UDID within the debounce window.
    private func publishBoot(udid: String) async {
        let now = Date()
        recentAuthoritativeBoots[udid] = now
        if let last = recentNotificationBoots[udid],
            now.timeIntervalSince(last) < debounceWindow {
            return
        }
        // `.everyone`: a udid leaks nothing `device.list` (daemon-wide)
        // doesn't already. If `device.list` is ever scoped, these move too.
        await eventBroker?.publish(.deviceBooted(udid: udid), to: .everyone)
    }

    /// Notification-path `deviceBooted` publish, used by
    /// `noteExternalBoot`. Skipped when either an authoritative
    /// publish or another notification fired for the same UDID
    /// within the window.
    private func publishBootDebounced(udid: String, arrivedAt now: Date = Date()) async {
        let lastAuth = recentAuthoritativeBoots[udid]
        let lastNotif = recentNotificationBoots[udid]
        recentNotificationBoots[udid] = now
        if let lastAuth, now.timeIntervalSince(lastAuth) < debounceWindow {
            return
        }
        if let lastNotif, now.timeIntervalSince(lastNotif) < debounceWindow {
            return
        }
        // `.everyone`: a udid leaks nothing `device.list` (daemon-wide)
        // doesn't already. If `device.list` is ever scoped, these move too.
        await eventBroker?.publish(.deviceBooted(udid: udid), to: .everyone)
    }

    /// Authoritative `deviceShutdown` publish, used by `shutdown()`
    /// and `releaseOwnership()`. Mirror of `publishBoot`.
    private func publishShutdown(udid: String) async {
        let now = Date()
        recentAuthoritativeShutdowns[udid] = now
        if let last = recentNotificationShutdowns[udid],
            now.timeIntervalSince(last) < debounceWindow {
            return
        }
        await eventBroker?.publish(.deviceShutdown(udid: udid), to: .everyone)
    }

    /// Notification-path `deviceShutdown` admission, used by
    /// `noteExternalShutdown`. Records this arrival and answers whether it
    /// is the one that should publish.
    ///
    /// Split into a decision instead of mirroring `publishBootDebounced`'s
    /// decide-and-publish shape because pane convergence follows this call
    /// and the notifier's consumer handles events one at a time. The next
    /// notification waits out that convergence before it can be admitted,
    /// so both halves of the debounce, the window comparison and recording
    /// this arrival, settle synchronously against `arrivedAt` (see
    /// `NotifierArrival`) rather than whenever a handler reaches them. The
    /// boot path has no comparable work and needs no split.
    private func admitNotificationShutdown(udid: String, arrivedAt now: Date) -> Bool {
        let lastAuth = recentAuthoritativeShutdowns[udid]
        let lastNotif = recentNotificationShutdowns[udid]
        recentNotificationShutdowns[udid] = now
        if let lastAuth, now.timeIntervalSince(lastAuth) < debounceWindow {
            return false
        }
        if let lastNotif, now.timeIntervalSince(lastNotif) < debounceWindow {
            return false
        }
        return true
    }

    // MARK: - Boot-claim convergence

    private func strongest(
        _ lhs: BootClaimObservedState,
        _ rhs: BootClaimObservedState
    ) -> BootClaimObservedState {
        func rank(_ state: BootClaimObservedState) -> Int {
            switch state {
            case .requested:
                0

            case .booting:
                1

            case .booted:
                2
            }
        }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }

    private func bootClaimResult(
        attemptId: UUID,
        record: BootClaimRecord,
        status: BootClaimStatus? = nil
    ) -> DeviceReconcileBootClaimResult {
        let resolvedStatus = status ?? record.status
        return DeviceReconcileBootClaimResult(
            attemptId: attemptId.uuidString.lowercased(),
            udid: record.evidence.udid,
            status: resolvedStatus,
            sessionId: resolvedStatus == .promoted && record.evidence.disposition == .attach
                ? record.sessionId?.uuidString
                : nil
        )
    }

    private func expireBootClaims(now: UInt64) {
        closedBootSessions = closedBootSessions.filter {
            $0.value.expiresAtNanoseconds > now
        }
        for attemptId in Array(bootClaims.keys) {
            guard var record = bootClaims[attemptId] else { continue }
            if record.status == .pending, now >= record.expiresAtNanoseconds {
                record.status = .expired
                bootClaims[attemptId] = record
                if activeBootClaimByUDID[record.evidence.udid] == attemptId {
                    activeBootClaimByUDID.removeValue(forKey: record.evidence.udid)
                }
            }
            guard record.status != .pending else { continue }
            let removal = record.expiresAtNanoseconds.addingReportingOverflow(
                Self.bootClaimTerminalRetentionNanoseconds
            )
            if !removal.overflow, now >= removal.partialValue {
                bootClaims.removeValue(forKey: attemptId)
            }
        }
    }

    private func ensureClosedBootSessionCleaner() {
        guard closedBootSessionCleaner == nil, !closedBootSessions.isEmpty else { return }
        closedBootSessionCleaner = Task { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: BootClaimEvidence.maximumLeaseMilliseconds * 1_000_000
                )
            } catch {
                return
            }
            await self?.closedBootSessionCleanerFired()
        }
    }

    private func closedBootSessionCleanerFired() {
        closedBootSessionCleaner = nil
        expireBootClaims(now: deviceSnapshotClock())
        ensureClosedBootSessionCleaner()
    }

    private func cancelBootClaim(forUDID udid: String) {
        guard let attemptId = activeBootClaimByUDID.removeValue(forKey: udid),
            var record = bootClaims[attemptId], record.status == .pending else { return }
        record.status = .canceled
        bootClaims[attemptId] = record
    }

    /// Make a causally established claim eligible for promotion. GUI claims
    /// reach this only in the same actor turn in which CoreSimulator accepts
    /// their boot intent; shim and restored claims arrive already established.
    private func activateBootClaim(_ attemptId: UUID) {
        guard let record = bootClaims[attemptId], record.status == .pending else { return }
        let udid = record.evidence.udid
        if let displaced = activeBootClaimByUDID[udid], displaced != attemptId,
            var prior = bootClaims[displaced], prior.status == .pending {
            prior.status = .superseded
            bootClaims[displaced] = prior
        }
        activeBootClaimByUDID[udid] = attemptId
        ensureBootClaimPoller()
    }

    /// A failed duplicate must not invalidate a claim whose earlier boot was
    /// already accepted. Only an inactive candidate belongs to this failure.
    private func failPreparedBootClaim(_ attemptId: UUID?) {
        guard let attemptId, var record = bootClaims[attemptId],
            record.status == .pending,
            activeBootClaimByUDID[record.evidence.udid] != attemptId else { return }
        record.status = .failed
        bootClaims[attemptId] = record
    }

    /// Module-internal seam for the failed-duplicate regression test. The
    /// production boot path calls the UUID-shaped helper in the same actor turn
    /// as the CoreSimulator failure.
    func failPreparedBootClaim(attemptId: String) {
        failPreparedBootClaim(UUID(uuidString: attemptId))
    }

    private func promoteBootClaim(attemptId: UUID) async -> Bool {
        guard var record = bootClaims[attemptId], record.status == .pending,
            activeBootClaimByUDID[record.evidence.udid] == attemptId else { return false }
        let now = deviceSnapshotClock()
        guard now < record.expiresAtNanoseconds else {
            expireBootClaims(now: now)
            return false
        }
        switch record.evidence.disposition {
        case .attach:
            guard let sessionId = record.sessionId else {
                record.status = .failed
                bootClaims[attemptId] = record
                activeBootClaimByUDID.removeValue(forKey: record.evidence.udid)
                return false
            }
            ownership[record.evidence.udid] = sessionId

        case .detach, .shutdown:
            ownership[record.evidence.udid] = UUID?.none
        }
        record.status = .promoted
        bootClaims[attemptId] = record
        activeBootClaimByUDID.removeValue(forKey: record.evidence.udid)
        await publishBoot(udid: record.evidence.udid)
        if record.evidence.disposition == .shutdown {
            try? await shutdown(udid: record.evidence.udid)
        }
        return true
    }

    private func ensureBootClaimPoller() {
        guard bootClaimPoller == nil,
            activeBootClaimByUDID.values.contains(where: {
                bootClaims[$0]?.status == .pending
            }) else { return }
        bootClaimPoller = Task { [weak self] in
            while !Task.isCancelled, await self?.pollBootClaims() == true {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    break
                }
            }
            await self?.bootClaimPollerFinished()
        }
    }

    private func pollBootClaims() async -> Bool {
        expireBootClaims(now: deviceSnapshotClock())
        let pending = activeBootClaimByUDID.compactMap { udid, attemptId in
            bootClaims[attemptId]?.status == .pending ? (attemptId, udid) : nil
        }
        guard !pending.isEmpty else { return false }
        let booted: Set<String>?
        do {
            booted = try await bootedUDIDs()
        } catch {
            return true
        }
        guard let booted else { return true }
        for (attemptId, udid) in pending where booted.contains(udid) {
            _ = await promoteBootClaim(attemptId: attemptId)
        }
        return activeBootClaimByUDID.values.contains {
            bootClaims[$0]?.status == .pending
        }
    }

    private func bootClaimPollerFinished() {
        bootClaimPoller = nil
        ensureBootClaimPoller()
    }

    // MARK: - Internal helpers

    /// Whether deviceterm owns this (normalized) udid at all, attributed or
    /// not.
    private func owns(_ normalized: String) -> Bool {
        ownership.index(forKey: normalized) != nil
    }

    /// The session attributed to this (normalized) udid. Nil both for a sim
    /// deviceterm owns unattributed and for one it doesn't own; callers that
    /// need to tell those apart ask `owns(_:)` too.
    private func owner(of normalized: String) -> UUID? {
        // The outer level answers "owned"; the inner one is the attribution,
        // and returning it unchanged is the point.
        guard let attribution = ownership[normalized] else { return nil }
        return attribution
    }

    /// Canonicalize a UDID for use as an ownership-map key.
    ///
    /// CoreSimulator UDIDs are standard UUIDs (8-4-4-4-12 hex,
    /// case-insensitive). Rejecting anything that doesn't parse as a
    /// UUID keeps junk strings out of the ownership map: without it,
    /// a malformed shim event or buggy caller can inflate
    /// `ownedCount` for a device that can never be in CoreSimulator's
    /// enumeration, which would lie to the status-item count and to
    /// every `device.list({scope: "owned"})` consumer.
    private func requireValidUDID(_ udid: String) throws -> String {
        let trimmed = udid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = UUID(uuidString: trimmed) else {
            throw DeviceError.malformedUDID(udid: udid)
        }
        return parsed.uuidString.lowercased()
    }
}
