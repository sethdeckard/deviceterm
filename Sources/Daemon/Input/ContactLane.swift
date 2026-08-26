// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol
import Foundation

/// Per-pane arbitration for the input verbs that hold digitizer
/// contact.
///
/// A pane has one shared digitizer stream. Every paced verb holds contact on it
/// across a suspension, and a live drag spans several RPCs, so two requests on
/// one pane can interleave into `down(A) down(B) up(A) up(B)`: successive downs
/// read as continued contact and the first up clears it, merging two gestures
/// into one. `PaneCoordinator` is an actor, but it releases isolation the moment
/// a gesture awaits into `SimInputSynthesis`, so actor isolation alone does not
/// order them.
///
/// The lane is its own actor rather than fields on `Record` because admission
/// suspends, and the checks around each suspension have to be uninterruptible.
/// Every transition is keyed by lease identity, so a stale releaser cannot free
/// a lease that has since been handed to someone else.
///
/// Membership is contact-producing verbs only. `crown`, `key`, `text`, `button`,
/// and `rotate` hold no contact and never enter.
actor ContactLane {
    enum Role: Equatable {
        case live
        /// A gesture holding contact across suspensions. `tap` and the App
        /// Switcher are not preemptible: a tap is two frames long and cutting it
        /// short reintroduces the too-short contact the dwell exists to prevent,
        /// and the App Switcher's trajectory only reads as a gesture whole.
        case composite(preemptible: Bool)
    }

    /// The contact flavor and payload a synthesized release has to mirror. A
    /// plain touch releases with `tapUp`, an edge touch with `edgeTouchUp`, and
    /// a two-finger contact with `twoFingerUp`; sending the wrong one leaves the
    /// guest holding a finger down.
    enum LiveContact: Equatable {
        case plain(CGPoint)
        case edge(CGPoint, edge: Int)
        case multi(CGPoint, CGPoint)

        /// Whether `other` releases the same kind of contact this opened.
        ///
        /// A plain `tapUp` does not release a two-finger contact, and sending
        /// it would report a lift for a finger that isn't the one down while
        /// leaving the real contacts held. Two live producers on one pane can
        /// produce exactly that ordering, so the mismatch is refused rather
        /// than sent.
        func matchesFlavor(of other: LiveContact) -> Bool {
            switch (self, other) {
            case (.plain, .plain), (.edge, .edge), (.multi, .multi):
                true

            default:
                false
            }
        }
    }

    /// What the caller should do with an admitted live phase.
    struct LiveAdmission: Equatable {
        static let drop = LiveAdmission(send: false, releaseAfterSend: nil)
        static let pass = LiveAdmission(send: true, releaseAfterSend: nil)

        /// Whether to pass the phase through to the backend. False for a lift
        /// with no compatible live lease: it is a duplicate or a leftover, and
        /// passing it through would release contact belonging to a `tap` or an
        /// App Switcher.
        let send: Bool
        /// Non-nil for a lift admitted against the matching live lease. The
        /// caller releases *after* its send, because
        /// freeing the lane first would let the next gesture put its `down` on
        /// the wire ahead of this `up`, which is the interleaving the lane
        /// exists to prevent.
        let releaseAfterSend: UInt64?
    }

    /// Handed to an admitted composite. The fence is how the lane asks a
    /// preemptible holder to release early.
    struct CompositeTicket: Sendable {
        let id: UInt64
        let fence: GestureFence
    }

    /// What a woken waiter receives: the identity of the lease it now holds.
    /// The `Lease` itself stays inside the actor, since it is mutable state the
    /// lane owns.
    private struct Grant: Sendable {
        let leaseId: UInt64
        let fence: GestureFence
    }

    private final class Lease {
        let id: UInt64
        let role: Role
        let generation: UInt64
        let fence: GestureFence
        var lastLive: LiveContact?
        var lastAdmitted: ContinuousClock.Instant
        /// Set once a preempt has been requested, so a second live arrival
        /// doesn't raise the fence again or queue a redundant expiry.
        var releasing = false
        /// Set when a lift has been admitted against this lease. A second
        /// concurrent lift would otherwise be handed the same id, and its `up`
        /// could land after the first released and the lane moved on.
        var lifting = false

        init(id: UInt64, role: Role, generation: UInt64, at now: ContinuousClock.Instant) {
            self.id = id
            self.role = role
            self.generation = generation
            self.fence = GestureFence()
            self.lastAdmitted = now
        }
    }

    private final class Waiter {
        let id: UInt64
        let role: Role
        let generation: UInt64
        var resumed = false
        /// The lease handed to this waiter. Held here because `finish` can
        /// resume the waiter before `enqueue` has installed its continuation,
        /// and dropping the grant in that window would leave a lease nobody
        /// owns and a lane nothing can free.
        var grant: Grant?
        var continuation: CheckedContinuation<Grant?, Never>?

        init(id: UInt64, role: Role, generation: UInt64) {
            self.id = id
            self.role = role
            self.generation = generation
        }

        /// Resume exactly once, with the lease this waiter now owns or nil if
        /// it will never get one. A waiter can be woken by a release, a close,
        /// a transfer, or its own cancellation, and more than one of those can
        /// reach it.
        func resume(_ grant: Grant?) {
            guard !resumed else { return }
            resumed = true
            self.grant = grant
            continuation?.resume(returning: grant)
            continuation = nil
        }
    }

    /// How long a live lease survives without an admitted phase before the lane
    /// assumes its producer is gone and frees the contact.
    ///
    /// The GUI refreshes a held single-finger or edge contact every 33ms, so
    /// those never approach it. Multitouch has no keepalive, and a client
    /// driving `pane.input.*` directly has none either, so both have to keep
    /// sending phases. It bounds the damage from a producer that sends `down`
    /// and then stops: without it, that pane's contact is held until close.
    static let liveExpiryMs: Int = 2_000

    private let pacer: any GesturePacing
    /// Frees a contact the lane has given up on.
    ///
    /// A live lease knows exactly what it opened, so it names the contact. A
    /// composite that failed partway does not: it never reported its points to
    /// the lane, and its terminal `up` may or may not have landed. `nil` means
    /// "release whatever is still down", which the backend tracks.
    private let recoverContact: @Sendable (LiveContact?, UInt64) async -> Bool

    private var current: Lease?
    /// Live arrivals jump ahead of queued composites, because a human drag must
    /// not wait out a backlog of scripted verbs. Two FIFO queues rather than
    /// head insertion: inserting at the head would make several live waiters
    /// resume last-in-first-out.
    private var liveWaiters: [Waiter] = []
    private var compositeWaiters: [Waiter] = []
    private var nextLeaseId: UInt64 = 1
    private var nextWaiterId: UInt64 = 1
    private var expiry: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set when a contact recovery reported failure. The backend may still be
    /// holding a finger down, so nothing new is admitted until a retry lands.
    private var unrecovered = false
    private var closed = false

    /// Whether a gesture is currently holding the lane, which is what tells the
    /// coordinator a close has to defer its cleanup.
    var hasActiveComposite: Bool {
        guard let lease = current else { return false }
        if case .composite = lease.role { return true }
        return false
    }

    init(
        pacer: any GesturePacing = SystemGesturePacer(),
        recoverContact: @escaping @Sendable (LiveContact?, UInt64) async -> Bool
    ) {
        self.pacer = pacer
        self.recoverContact = recoverContact
    }

    // MARK: - Admission

    /// Take the lane for a gesture that holds contact across suspensions.
    ///
    /// Returns nil when the lane closed, the pane transferred, contact recovery
    /// has not yet succeeded, or the caller's own task was cancelled while
    /// queued. A nil ticket means send nothing.
    func admitComposite(preemptible: Bool, generation: UInt64) async -> CompositeTicket? {
        guard !closed, !unrecovered else { return nil }
        let role = Role.composite(preemptible: preemptible)
        if current != nil || !compositeWaiters.isEmpty || !liveWaiters.isEmpty {
            // The lease is minted by whoever hands the lane over, so there is
            // no window between the previous holder dropping it and this one
            // taking it.
            guard let grant = await enqueue(role: role, generation: generation) else { return nil }
            return CompositeTicket(id: grant.leaseId, fence: grant.fence)
        }
        let lease = take(role: role, generation: generation)
        return CompositeTicket(id: lease.id, fence: lease.fence)
    }

    /// Admit one phase of a live contact stream.
    ///
    /// `.lift` never queues: it can only release contact, and blocking it is the
    /// one thing that could strand a finger down.
    func admitLive(
        phase: TouchPhase,
        contact: LiveContact,
        generation: UInt64
    ) async -> LiveAdmission {
        if phase == .lift {
            guard let lease = current,
                lease.role == .live,
                !lease.lifting,
                lease.generation == generation,
                lease.lastLive?.matchesFlavor(of: contact) ?? false else {
                return .drop
            }
            lease.lifting = true
            // Held until the caller reports the release landed.
            return LiveAdmission(send: true, releaseAfterSend: lease.id)
        }
        guard !closed, !unrecovered else { return .drop }
        // A live lease already holds the lane. Refresh it and pass through: the
        // digitizer has one contact, so two live producers on one pane are
        // already indistinguishable at the HID layer. Arbitrating between them
        // needs a wire-level stream identity that does not exist yet.
        if let lease = current, lease.role == .live {
            lease.lastLive = contact
            lease.lastAdmitted = pacer.now()
            armExpiry(for: lease.id)
            return .pass
        }
        if let lease = current {
            // Held by a composite. Ask a preemptible one to release; wait out an
            // unpreemptible one. Either way this arrival queues.
            if case let .composite(preemptible) = lease.role, preemptible, !lease.releasing {
                lease.releasing = true
                lease.fence.requestPreempt()
            }
            guard let grant = await enqueue(role: .live, generation: generation) else { return .drop }
            noteLiveContact(grant.leaseId, contact: contact)
            return .pass
        }
        let lease = take(role: .live, generation: generation)
        lease.lastLive = contact
        armExpiry(for: lease.id)
        return .pass
    }

    // MARK: - Release

    /// Give up a lease. Idempotent, and a no-op when `id` is not the lease
    /// currently held: a gesture that ended after a transfer already lost it.
    func release(_ id: UInt64) {
        guard current?.id == id else { return }
        finish(id)
    }

    /// Give up a lease whose gesture threw partway.
    ///
    /// The terminal `up` may never have landed, so the contact's state is
    /// unknown and handing the lane straight to the next gesture would stack it
    /// on a finger that could still be down. Hold the lease and let the
    /// abandonment timer free the lane instead: the wait is the same bound an
    /// abandoned live contact gets, and it releases what it knows about.
    func releaseAfterFailure(_ id: UInt64) {
        guard let lease = current, lease.id == id else { return }
        guard !closed else {
            // The pane is already closing, and its teardown owns the contact
            // from here: it retries the release itself for a detach, and a
            // shutdown takes the device with it. Holding the lease would block
            // that teardown waiting for a recovery it is the one performing.
            finish(id)
            return
        }
        unrecovered = true
        lease.lastAdmitted = pacer.now()
        armExpiry(for: id)
    }

    // MARK: - Lifecycle

    /// Stop admitting, wake every waiter, and free an abandoned live contact.
    ///
    /// An active composite is left alone to finish. The coordinator holds the
    /// pane's machinery open for it and cleans up once it releases.
    func close() async {
        closed = true
        cancelWaiters()
        if unrecovered {
            // The holder's gesture already ended; the lease was only being kept
            // so nothing else took the lane over a contact that might still be
            // down. The pane's teardown owns that contact now, and it makes one
            // more attempt to free it before the backend goes away.
            unrecovered = false
            current = nil
            expiry?.cancel()
            expiry = nil
            signalIdleIfQuiet()
            return
        }
        if let lease = current, lease.role == .live {
            await recover(lease)
            current = nil
            expiry?.cancel()
            expiry = nil
        }
        signalIdleIfQuiet()
    }

    /// Hard boundary: an ownership transfer invalidated everything in flight.
    ///
    /// The backend quiesce that follows invalidates the holder's remaining
    /// sends and frees the contact, so nothing is emitted here.
    func transfer() {
        // The backend quiesce that follows invalidates the holder's sends and
        // frees whatever is down, so a failed recovery stops mattering.
        unrecovered = false
        cancelWaiters()
        current?.fence.requestPreempt()
        current = nil
        expiry?.cancel()
        expiry = nil
        signalIdleIfQuiet()
    }

    /// Resume once the lane is idle. Used by a deferred close to wait out the
    /// composite it let finish.
    ///
    /// Its own waiter list rather than the admission queue: this observes the
    /// lane going quiet, and must not be handed a lease of its own.
    func awaitIdle() async {
        guard current != nil else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            idleWaiters.append(continuation)
        }
    }

    private func signalIdleIfQuiet() {
        guard current == nil else { return }
        let waiting = idleWaiters
        idleWaiters.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }

    // MARK: - Internals

    /// Record the contact a freshly granted live lease opened with, so an
    /// expiry or a close can release the right flavor.
    private func noteLiveContact(_ id: UInt64, contact: LiveContact) {
        guard let lease = current, lease.id == id else { return }
        lease.lastLive = contact
        armExpiry(for: id)
    }

    private func take(role: Role, generation: UInt64) -> Lease {
        let lease = Lease(id: nextLeaseId, role: role, generation: generation, at: pacer.now())
        nextLeaseId &+= 1
        current = lease
        return lease
    }

    /// Drop the current lease and hand the lane to the next waiter, live first.
    ///
    /// The successor's lease is minted here, in the same actor step that clears
    /// the old one. Clearing `current` and letting the woken waiter take the
    /// lane itself would leave a gap for a fresh arrival to take it first, and
    /// then both would believe they held it.
    private func finish(_ id: UInt64) {
        guard current?.id == id else { return }
        current = nil
        expiry?.cancel()
        expiry = nil
        guard let waiter = dequeueNextWaiter() else {
            signalIdleIfQuiet()
            return
        }
        let lease = take(role: waiter.role, generation: waiter.generation)
        waiter.resume(Grant(leaseId: lease.id, fence: lease.fence))
    }

    private func dequeueNextWaiter() -> Waiter? {
        if !liveWaiters.isEmpty { return liveWaiters.removeFirst() }
        if !compositeWaiters.isEmpty { return compositeWaiters.removeFirst() }
        return nil
    }

    /// Queue for the lane and suspend. Resumes with the lease this waiter was
    /// handed, or nil if it will never get one (closed, transferred, or its own
    /// task was cancelled).
    private func enqueue(role: Role, generation: UInt64) async -> Grant? {
        let waiter = Waiter(id: nextWaiterId, role: role, generation: generation)
        nextWaiterId &+= 1
        if role == .live {
            liveWaiters.append(waiter)
        } else {
            compositeWaiters.append(waiter)
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Grant?, Never>) in
                // Already resumed between the append and here, by a close, a
                // transfer, or a handoff. Return whatever it was given: a
                // discarded grant would strand the lease `finish` already
                // installed as current.
                if waiter.resumed {
                    continuation.resume(returning: waiter.grant)
                } else {
                    waiter.continuation = continuation
                }
            }
        } onCancel: { [id = waiter.id] in
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Drop a waiter whose own task was cancelled, or whose connection went
    /// away. It resumes exactly once and never reaches the backend.
    private func cancelWaiter(_ id: UInt64) {
        let waiter = liveWaiters.first { $0.id == id } ?? compositeWaiters.first { $0.id == id }
        liveWaiters.removeAll { $0.id == id }
        compositeWaiters.removeAll { $0.id == id }
        waiter?.resume(nil)
    }

    private func cancelWaiters() {
        let waiting = liveWaiters + compositeWaiters
        liveWaiters.removeAll()
        compositeWaiters.removeAll()
        for waiter in waiting {
            waiter.resume(nil)
        }
    }

    /// Free whatever this lease was holding. Synchronous for a live lease so a
    /// close's lift is ordered ahead of the backend teardown; a failed
    /// composite has to ask the backend, which suspends.
    @discardableResult
    private func recover(_ lease: Lease) async -> Bool {
        await recoverContact(lease.lastLive, lease.generation)
    }

    /// Arm (or re-arm) the expiry for `id`.
    ///
    /// Keyed by lease id and revalidated after the wake, so a timer left over
    /// from a lease that has already ended cannot release a newer one.
    private func armExpiry(for id: UInt64) {
        expiry?.cancel()
        let deadline = pacer.now() + .milliseconds(Self.liveExpiryMs)
        expiry = Task { [weak self] in
            guard let self else { return }
            await self.pacer.sleep(until: deadline)
            guard !Task.isCancelled else { return }
            await self.expireIfStale(id, deadline: deadline)
        }
    }

    private func expireIfStale(_ id: UInt64, deadline: ContinuousClock.Instant) async {
        guard let lease = current, lease.id == id else { return }
        // `>=` rather than `>`: waking exactly on the deadline has to expire,
        // or the lease sits there with nothing scheduled to wake it again.
        guard pacer.now() >= deadline else { return }
        // Free the contact *before* handing the lane on. The recovery suspends
        // for a composite, so re-check the lease is still the current one
        // afterwards: a transfer or close can land in that window.
        let recovered = await recover(lease)
        guard let stillHeld = current, stillHeld.id == id else { return }
        guard recovered else {
            guard !closed else {
                // A close landed while this attempt was in flight. Its teardown
                // owns the contact now and is the thing that frees it, so
                // holding the lease would block the very work that recovers it.
                unrecovered = false
                finish(id)
                return
            }
            // The release failed, so the contact may still be down. Handing the
            // lane on would put the next gesture on top of it, which is the
            // interleaving this whole type exists to prevent, so the lane stays
            // shut and keeps trying. It reopens if a later attempt lands, and a
            // close or a transfer clears it either way.
            unrecovered = true
            stillHeld.lastAdmitted = pacer.now()
            armExpiry(for: id)
            return
        }
        unrecovered = false
        finish(id)
    }
}
