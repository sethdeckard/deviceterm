// SPDX-License-Identifier: GPL-3.0-or-later
//
// SubscriptionLifecycle: late-bound teardown coordinator for one XPC
// pane subscription, plus the context the transport threads into the
// subscription handler.
//
// A subscription's teardown causes (graceful drain, abrupt orphan) can
// arrive before the pieces that handle them exist: a drain can fire
// while the subscribe handler is still running, before `PaneCoordinator`
// has registered the pool token or `PaneMethods` has composed the
// producer cleanup. The lifecycle box absorbs that ordering: it records
// a cause the instant it arrives and applies each half (device pool
// teardown, producer unsubscribe) once its target installs.
//
// The box is universal across XPC *pane* subscriptions: every one gets
// one (non-pane subscriptions like events/app.commands don't). Only a
// device pane installs the pool teardown; a simulator subscription
// installs only the producer cleanup, so the transport path stays uniform.

import Foundation

/// Transport-created per-subscription context handed to a subscription
/// handler. `subscriptionToken` is the correlation key for the
/// connection's side-band surface lane (and, for a device pane, the
/// pool's lease token); `connectionId` is the registering connection,
/// used for the pool's connection-authority check. UDS subscriptions
/// pass `nil`: UDS vends no surface lane, so there is nothing to
/// correlate or drain.
public struct SubscriptionContext: Sendable {
    let subscriptionToken: UUID
    let connectionId: UInt64
    let lifecycle: SubscriptionLifecycle
    /// Pane-agnostic side-band delivery capability: marshals a
    /// `SurfaceSendInfo` and ships it on the registering connection's
    /// peer. Pane-agnostic by construction, it reads `info.paneId` and
    /// asserts no pane of its own, so the transport hands the
    /// coordinator the *ability* to deliver a surface without naming (or
    /// authorizing) a pane. `PaneCoordinator.subscribe` registers it
    /// against the authorized pane *after* the ownership gate, so a
    /// foreign subscribe never wires a delivery slot: registration happens
    /// only after ownership authorization.
    let surfaceDelivery: PaneSubscriptionRegistry.SurfaceDelivery

    init(
        subscriptionToken: UUID,
        connectionId: UInt64,
        lifecycle: SubscriptionLifecycle,
        surfaceDelivery: @escaping PaneSubscriptionRegistry.SurfaceDelivery
    ) {
        self.subscriptionToken = subscriptionToken
        self.connectionId = connectionId
        self.lifecycle = lifecycle
        self.surfaceDelivery = surfaceDelivery
    }
}

public actor SubscriptionLifecycle {
    /// A terminal teardown cause. Orphan dominates drain: an abrupt
    /// disconnect must keep held slots pinned even if a graceful drain
    /// was already in flight.
    enum Cause: Sendable, Equatable {
        case drain
        case orphan
    }

    private var pendingCause: Cause?
    private var appliedCause: Cause?
    private var poolTeardown: (@Sendable (Cause) async -> Void)?
    private var producerCleanup: (@Sendable () -> Void)?
    private var surfaceTeardown: (@Sendable () async -> Void)?
    private var surfaceToreDown = false
    private var cleanupRequested = false
    private var cleanupDone = false

    private static func dominant(_ existing: Cause?, _ incoming: Cause) -> Cause {
        if existing == .orphan || incoming == .orphan { return .orphan }
        return .drain
    }

    /// Install the device pool teardown (never installed for a sim or
    /// UDS subscription). Applies any already-queued cause immediately.
    func installPoolTeardown(_ teardown: @escaping @Sendable (Cause) async -> Void) async {
        poolTeardown = teardown
        await applyPendingCause()
    }

    /// Install the universal producer unsubscribe (the pool-free
    /// coordinator/adapter teardown). Fires it immediately if a terminal
    /// cause already requested cleanup.
    func installProducerCleanup(_ cleanup: @escaping @Sendable () -> Void) {
        producerCleanup = cleanup
        if cleanupRequested { fireProducerCleanup() }
    }

    /// Install the side-band **surface-hook** teardown (the registry
    /// `unregister` for this subscription's token). Because registration
    /// happens only after ownership authorization (the hook is wired
    /// *inside* `PaneCoordinator.subscribe`, after the handler's
    /// authorization await), a connection close or a drain that raced setup
    /// may fire the lifecycle before, during, or after registration. Tying
    /// the unregister to the lifecycle closes every ordering: if a terminal
    /// cause already fired, installing runs the teardown immediately
    /// (undoing a just-registered hook); if it fires later, `fire` runs it.
    /// So a hook can never outlive its subscription's teardown.
    func installSurfaceTeardown(_ teardown: @escaping @Sendable () async -> Void) async {
        surfaceTeardown = teardown
        if pendingCause != nil { await runSurfaceTeardown() }
    }

    /// Record a terminal cause: run the surface-hook teardown (the registry
    /// `unregister`, the synchronous no-further-send fence) FIRST, then
    /// apply the pool teardown (or defer it to install) and fire the
    /// producer cleanup. Ordering `runSurfaceTeardown()` before
    /// `applyPendingCause()` matters: the pool teardown can suspend, so
    /// removing the registry entry beforehand ensures a reentrant surface
    /// callback can't admit a delivery during that suspension. Orphan
    /// upgrades a prior drain; a drain never downgrades a prior orphan.
    func fire(_ cause: Cause) async {
        pendingCause = Self.dominant(pendingCause, cause)
        await runSurfaceTeardown()
        await applyPendingCause()
        cleanupRequested = true
        fireProducerCleanup()
    }

    /// Whether a terminal cause has been queued. `PaneCoordinator.subscribe`
    /// reads this before the initial replay and skips it when true.
    func hasTerminalCause() -> Bool { pendingCause != nil }

    private func applyPendingCause() async {
        guard let teardown = poolTeardown, let cause = pendingCause else { return }
        if appliedCause == .orphan { return }
        if appliedCause == cause { return }
        appliedCause = cause
        await teardown(cause)
    }

    private func fireProducerCleanup() {
        guard !cleanupDone, let cleanup = producerCleanup else { return }
        cleanupDone = true
        cleanup()
    }

    private func runSurfaceTeardown() async {
        guard !surfaceToreDown, let teardown = surfaceTeardown else { return }
        surfaceToreDown = true
        await teardown()
    }
}

/// Runs a closure at most once across every caller. A subscription's
/// producer cleanup is referenced by three independent paths (the local
/// pre-result `defer`, `SubscriptionResult.onCancel`, and
/// `SubscriptionLifecycle`) and must run exactly once no matter how many
/// of them fire. The serial queue gates the flag without an ad-hoc lock.
final class FireOnce: @unchecked Sendable {
    // Invariant: `fired` is read/written only inside `queue.sync`.
    private let queue = DispatchQueue(label: "deviceterm.daemon.fire-once")
    private var fired = false
    private let body: @Sendable () -> Void

    init(_ body: @escaping @Sendable () -> Void) {
        self.body = body
    }

    func callAsFunction() {
        let shouldRun: Bool = queue.sync {
            if fired { return false }
            fired = true
            return true
        }
        if shouldRun { body() }
    }
}
