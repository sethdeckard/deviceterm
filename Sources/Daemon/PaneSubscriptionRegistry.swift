// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneSubscriptionRegistry: single fan-out point for pane surface
// delivery, keyed by `(paneId, connectionId)`.
//
// JSON pane events fan out inside `PaneCoordinator` (each pane record
// carries its own subscriber continuations). This registry owns the
// orthogonal surface lane that UDS can't carry: each XPC subscription
// registers a synchronous send closure (it marshals a `RetainedSurface`
// into an `xpc_object_t` and ships it), and the registry routes per-pane
// surface fan-out to the right closures.
//
// For a **device** pane with leasing enabled, the registry runs the pool
// grant transaction for each subscription before the send (acquire a
// provisional hold, commit it *before* exposing the surface, then send)
// so a slot can't be reused while the GUI still holds the frame. The
// transaction is serialized per subscription through a bounded,
// latest-only worker, so exposure order equals reservation order and a
// stalled commit can't accumulate a backlog. Simulator frames (no lease)
// and the kill-switched path take no hold and send straight through.

import DaemonProtocol
import Foundation

public actor PaneSubscriptionRegistry {
    /// The synchronous, non-reentrant send: it only marshals the surface
    /// and calls `xpc_connection_send_message`. Kept synchronous so no
    /// `await` (and thus no actor reentrancy) can occur between the
    /// post-commit revalidation and the send.
    public typealias SurfaceDelivery = @Sendable (SurfaceSendInfo) -> Void

    /// Everything one side-band surface send needs. Carried to the
    /// synchronous send closure after any pool accounting has completed.
    public struct SurfaceSendInfo: Sendable {
        public let paneId: UUID
        public let sequence: UInt64
        public let surface: RetainedSurface
        /// Correlation key for this subscription's side-band lane (and,
        /// for a device pane, the pool lease token).
        public let subscriptionToken: UUID
        /// True when a pool hold is committed for this frame (device pane,
        /// leasing on); the GUI takes a lease and acks it. False for a
        /// simulator frame or the kill-switched path: no hold, no ack.
        public let leased: Bool
        /// The pool epoch the hold belongs to; meaningful only when
        /// `leased`.
        public let leaseEpoch: UInt64

        public init(
            paneId: UUID,
            sequence: UInt64,
            surface: RetainedSurface,
            subscriptionToken: UUID,
            leased: Bool,
            leaseEpoch: UInt64
        ) {
            self.paneId = paneId
            self.sequence = sequence
            self.surface = surface
            self.subscriptionToken = subscriptionToken
            self.leased = leased
            self.leaseEpoch = leaseEpoch
        }
    }

    /// One subscriber's record. JSON-event subscribers carry a
    /// continuation; surface-delivery subscribers carry the send closure.
    public struct Entry: Sendable {
        public let subscriptionId: UUID
        public let paneId: UUID
        public let connectionId: UInt64
        public let continuation: AsyncStream<PaneEvent>.Continuation?
        public let surfaceDelivery: SurfaceDelivery?

        public init(
            subscriptionId: UUID,
            paneId: UUID,
            connectionId: UInt64,
            continuation: AsyncStream<PaneEvent>.Continuation? = nil,
            surfaceDelivery: SurfaceDelivery? = nil
        ) {
            self.subscriptionId = subscriptionId
            self.paneId = paneId
            self.connectionId = connectionId
            self.continuation = continuation
            self.surfaceDelivery = surfaceDelivery
        }
    }

    /// Per-subscription delivery worker for the leased device path. At
    /// most one transaction runs at a time plus one newest-queued frame
    /// (the queue keeps the greater generation; an older arrival is
    /// dropped). Bounds retention and preserves exposure == reservation
    /// order.
    private final class DeliveryWorker {
        var running = false
        var queued: PublishedSurface?
    }

    /// Indexed by `subscriptionId` so register / unregister are O(1) and
    /// `dropAllForConnection` can sweep without touching every paneId.
    private var entries: [UUID: Entry] = [:]
    private var entriesByPane: [UUID: Set<UUID>] = [:]
    private var entriesByConnection: [UInt64: Set<UUID>] = [:]
    private var workers: [UUID: DeliveryWorker] = [:]
    /// Surface-delivery entries that have been **activated**. An authorized
    /// subscription registers its entry *dormant* (present but non-
    /// delivering) so the coordinator can install the lifecycle teardown
    /// before any frame can ship; only once it has confirmed the
    /// subscription isn't already torn down does it `activate` the entry.
    /// A dormant entry is skipped by delivery, closing the window where a
    /// frame could ship between registration and teardown. `register`
    /// (the JSON+surface path) activates immediately.
    private var active: Set<UUID> = []

    /// Global per-frame leasing switch (`DEVICETERM_SURFACE_LEASES`). When
    /// off, device frames deliver like simulator frames (no holds, no
    /// acks) but the token/drain subscription lifecycle stays on.
    private let leasingEnabled: Bool

    public init(leasingEnabled: Bool = true) {
        self.leasingEnabled = leasingEnabled
    }

    // MARK: - Registration

    /// Register a new JSON+surface subscription. Returns the subscription
    /// id (also the lease token) the caller passes to `unregister`.
    @discardableResult
    public func register(
        paneId: UUID,
        connectionId: UInt64,
        continuation: AsyncStream<PaneEvent>.Continuation,
        surfaceDelivery: SurfaceDelivery? = nil
    ) -> UUID {
        let subscriptionId = UUID()
        insert(
            Entry(
                subscriptionId: subscriptionId,
                paneId: paneId,
                connectionId: connectionId,
                continuation: continuation,
                surfaceDelivery: surfaceDelivery
            )
        )
        active.insert(subscriptionId)
        return subscriptionId
    }

    /// Register a delivery-only entry (XPC surface lane; JSON evts flow
    /// through `PaneCoordinator`'s per-record subscribers map) under a
    /// **caller-provided** `subscriptionId`. The id is the connection's
    /// side-band token, minted early in the transport (so an id-less
    /// `pane.surfaceDrain` can correlate) and registered here only after
    /// `PaneCoordinator.subscribe` authorizes the pane, so foreign or
    /// rejected subscriptions never enter the registry. The same token the
    /// pool lease and the GUI's acks use, so there is one id,
    /// not two.
    public func registerSurfaceDelivery(
        paneId: UUID,
        connectionId: UInt64,
        subscriptionId: UUID,
        surfaceDelivery: @escaping SurfaceDelivery
    ) {
        insert(
            Entry(
                subscriptionId: subscriptionId,
                paneId: paneId,
                connectionId: connectionId,
                surfaceDelivery: surfaceDelivery
            )
        )
        // Registered dormant: `activate` makes it deliver.
    }

    /// Activate a dormant surface-delivery entry so it begins delivering.
    /// Called by `PaneCoordinator.subscribe` only after it has installed
    /// the lifecycle teardown and confirmed the subscription isn't already
    /// terminal, so no frame ships before the no-further-send fence is in
    /// place. A no-op if the entry was already unregistered (a terminal
    /// cause tore it down first).
    public func activate(subscriptionId: UUID) {
        guard entries[subscriptionId] != nil else { return }
        active.insert(subscriptionId)
    }

    private func insert(_ entry: Entry) {
        entries[entry.subscriptionId] = entry
        entriesByPane[entry.paneId, default: []].insert(entry.subscriptionId)
        entriesByConnection[entry.connectionId, default: []].insert(entry.subscriptionId)
        if entry.surfaceDelivery != nil {
            workers[entry.subscriptionId] = DeliveryWorker()
        }
    }

    /// Remove one subscription. Closes admission for its delivery worker
    /// (the queued frame is discarded; any in-flight transaction observes
    /// the missing entry at its next revalidation and cancels/revokes its
    /// hold). The continuation is not finished here: callers choose
    /// finish-vs-leave semantics.
    public func unregister(subscriptionId: UUID) {
        active.remove(subscriptionId)
        guard let entry = entries.removeValue(forKey: subscriptionId) else {
            return
        }
        removeIndexes(entry)
        workers.removeValue(forKey: subscriptionId)
    }

    private func removeIndexes(_ entry: Entry) {
        entriesByPane[entry.paneId]?.remove(entry.subscriptionId)
        if entriesByPane[entry.paneId]?.isEmpty == true {
            entriesByPane.removeValue(forKey: entry.paneId)
        }
        entriesByConnection[entry.connectionId]?.remove(entry.subscriptionId)
        if entriesByConnection[entry.connectionId]?.isEmpty == true {
            entriesByConnection.removeValue(forKey: entry.connectionId)
        }
    }

    /// Drop every entry whose `connectionId` matches, finishing each
    /// continuation. Called on XPC connection invalidation.
    public func dropAllForConnection(connectionId: UInt64) {
        guard let ids = entriesByConnection.removeValue(forKey: connectionId) else {
            return
        }
        for subscriptionId in ids {
            active.remove(subscriptionId)
            guard let entry = entries.removeValue(forKey: subscriptionId) else {
                continue
            }
            entriesByPane[entry.paneId]?.remove(subscriptionId)
            if entriesByPane[entry.paneId]?.isEmpty == true {
                entriesByPane.removeValue(forKey: entry.paneId)
            }
            workers.removeValue(forKey: subscriptionId)
            entry.continuation?.finish()
        }
    }

    // MARK: - JSON event fan-out

    /// Yield an event to every JSON subscriber on `paneId`.
    public func yieldEvent(paneId: UUID, event: PaneEvent) {
        guard let ids = entriesByPane[paneId] else { return }
        for subscriptionId in ids {
            entries[subscriptionId]?.continuation?.yield(event)
        }
    }

    // MARK: - Surface delivery

    /// Deliver a fresh frame to every surface subscriber on `paneId`
    /// (live fan-out).
    func deliverSurface(paneId: UUID, published: PublishedSurface, sequence: UInt64) {
        guard let ids = entriesByPane[paneId] else { return }
        for subscriptionId in ids {
            dispatchDelivery(subscriptionId: subscriptionId, published: published, sequence: sequence)
        }
    }

    /// Deliver a frame to a single subscription (the token-targeted
    /// initial replay). A no-op if the id is unknown or has no send hook.
    func deliverSurface(to subscriptionId: UUID, published: PublishedSurface, sequence: UInt64) {
        dispatchDelivery(subscriptionId: subscriptionId, published: published, sequence: sequence)
    }

    /// Route one frame to one subscription: through the grant worker for a
    /// leased device frame, or straight to the send for a simulator frame
    /// / the kill-switched path.
    private func dispatchDelivery(subscriptionId: UUID, published: PublishedSurface, sequence: UInt64) {
        // A dormant (registered-but-not-yet-activated) entry never delivers.
        guard active.contains(subscriptionId),
            let entry = entries[subscriptionId], let send = entry.surfaceDelivery else { return }
        if leasingEnabled, published.lease != nil {
            enqueueLeasedDelivery(subscriptionId: subscriptionId, published: published)
        } else {
            send(
                SurfaceSendInfo(
                    paneId: entry.paneId,
                    sequence: sequence,
                    surface: published.surface,
                    subscriptionToken: subscriptionId,
                    leased: false,
                    leaseEpoch: 0
                )
            )
        }
    }

    /// Admit a leased frame to the subscription's worker. If a transaction
    /// is already running, keep the greater generation as the single
    /// queued job (an older arrival, e.g. a replay racing live delivery,
    /// is dropped, not swapped in). Otherwise start the worker.
    private func enqueueLeasedDelivery(subscriptionId: UUID, published: PublishedSurface) {
        guard let worker = workers[subscriptionId] else { return }
        if worker.running {
            if let queued = worker.queued,
                let queuedGen = queued.lease?.generation,
                let incomingGen = published.lease?.generation,
                incomingGen <= queuedGen {
                return
            }
            worker.queued = published
            return
        }
        worker.running = true
        Task { await self.drainWorker(subscriptionId: subscriptionId, first: published) }
    }

    /// Run the subscription's queued transactions one at a time until the
    /// queue drains. Each transaction is a full acquire → commit → send
    /// unit, so no later generation is exposed before an earlier one.
    private func drainWorker(subscriptionId: UUID, first: PublishedSurface) async {
        var current: PublishedSurface? = first
        while let published = current {
            await runLeasedTransaction(subscriptionId: subscriptionId, published: published)
            current = workers[subscriptionId]?.queued
            workers[subscriptionId]?.queued = nil
        }
        workers[subscriptionId]?.running = false
    }

    /// One grant transaction: reserve a provisional hold, revalidate the
    /// entry after each `await`, commit **before** the send, and send with
    /// no further suspension. Any pre-commit failure cancels the hold; a
    /// post-commit revalidation failure revokes it; a rejected grant drops
    /// the frame. Once sent, only an accepted watermark ack releases the
    /// hold. Orphaning preserves it (pinned, never force-freed).
    private func runLeasedTransaction(subscriptionId: UUID, published: PublishedSurface) async {
        guard let lease = published.lease else { return }
        guard let grant = await lease.acquireHold(subscriptionId) else { return }
        guard entries[subscriptionId] != nil else {
            await grant.cancel()
            return
        }
        guard await grant.commit() else {
            await grant.cancel()
            return
        }
        guard let entry = entries[subscriptionId], let send = entry.surfaceDelivery else {
            await grant.revoke()
            return
        }
        send(
            SurfaceSendInfo(
                paneId: entry.paneId,
                sequence: lease.generation,
                surface: published.surface,
                subscriptionToken: subscriptionId,
                leased: true,
                leaseEpoch: lease.epoch
            )
        )
    }

    // MARK: - Introspection (tests)

    public func subscriberCount(paneId: UUID) -> Int {
        entriesByPane[paneId]?.count ?? 0
    }

    public func subscriberCount(connectionId: UInt64) -> Int {
        entriesByConnection[connectionId]?.count ?? 0
    }

    /// Whether any surface-delivery entry exists for `(paneId,
    /// connectionId)`. Test-facing: the frame-leak guard asserts a
    /// foreign subscribe wired **no** `(victimPaneId, attackerConnection)`
    /// hook, since foreign or rejected subscriptions never enter the
    /// registry: an absence a property `subscriberCount(paneId:)` (which
    /// counts all connections) can't express.
    public func hasEntry(paneId: UUID, connectionId: UInt64) -> Bool {
        guard let ids = entriesByPane[paneId] else { return false }
        return ids.contains { entries[$0]?.connectionId == connectionId }
    }
}
