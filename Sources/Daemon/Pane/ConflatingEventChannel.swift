// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// One subscriber's pending pane events, with the surface and hinge notices
/// each conflated to the newest in a slot of their own.
///
/// A pane publishes `surfaceChanged` at the display's rate and `hingeChanged`
/// at the device's sampling rate while a fold is under way. A consumer that
/// falls behind therefore accumulates those two and almost nothing else, so
/// this keeps **at most one** of each pending per subscriber and lets lifecycle
/// and orientation events queue in full. Losing a `shutdown` to make room for a
/// frame notice would trade a bounded queue for a pane that never learns it
/// died, and only the newest angle is worth anything anyway.
///
/// The lossless queue has no cap. Its producers are lifecycle transitions and
/// rotations, which arrive at human rates; the fast lanes are the ones that
/// needed bounding, and each is bounded at one. `EventBroker` is left unbounded
/// for the same reason.
///
/// **Conflation must not reorder.** A newer surface notice drops the pending
/// one and takes a place at the back, keeping frames behind every event that
/// preceded them. Holding the old slot instead would deliver the newest
/// framebuffer ahead of a rotation it actually came after, and the consumer
/// would render it against the old orientation. A terminal state seals the
/// slot: nothing after `shutdown` or `failed` can emit a frame notice for a
/// pane that is gone.
///
/// `@unchecked Sendable`: the reference is handed to a reader so it can keep
/// draining after its subscriber record is gone. Production access is
/// serialized by `PaneCoordinator`; nothing here takes a lock, so a direct
/// test must likewise keep its access single-task and non-concurrent.
/// `PaneEventStream` is the consumer's view.
final class ConflatingEventChannel: @unchecked Sendable {
    /// Queued events in delivery order. A pending surface notice occupies one
    /// entry here; `pendingSurfaceIndex` says which.
    private var queue: [PaneEvent] = []
    /// Where the single pending surface notice sits in `queue`, if any.
    private var pendingSurfaceIndex: Int?
    /// Where the single pending hinge notice sits in `queue`, if any. A second
    /// conflatable slot, which is why every removal goes through
    /// `removeQueued(at:)`: dropping one slot's entry moves the other's index.
    private var pendingHingeIndex: Int?
    /// Set once a terminal state is queued. Later surface notices are dropped
    /// rather than queued behind it.
    private var sealed = false
    private var finished = false
    /// The consumer parked in `next()`, resumed by the next `send` or
    /// `finish`. Caller precondition: one reader per channel. A second parked
    /// reader would replace the first, which nothing here detects.
    private var waiter: CheckedContinuation<PaneEvent?, Never>?
    /// Cumulative surface notices dropped by conflation.
    private(set) var conflatedSurfaceCount = 0

    var pendingCount: Int { queue.count }
    var isSealed: Bool { sealed }
    var isFinished: Bool { finished }
    /// Whether a reader is parked. Reached only through `PaneCoordinator`, so
    /// the read stays on the actor like every other access here.
    var hasParkedReader: Bool { waiter != nil }

    /// Queue `event`, resuming a parked consumer.
    ///
    /// Handing an event straight to a waiting consumer keeps the queue empty on
    /// the common path: the queue only grows once the consumer stops asking.
    func send(_ event: PaneEvent) {
        guard !finished else { return }
        // The seal is checked before every other path, including the handoff
        // to a parked consumer: a frame notice must not reach a subscriber
        // that has already been told the pane is gone.
        if case .surfaceChanged = event, sealed {
            conflatedSurfaceCount += 1
            return
        }
        if let waiter {
            self.waiter = nil
            noteTerminal(event)
            waiter.resume(returning: event)
            return
        }
        switch event {
        case .surfaceChanged:
            if let index = pendingSurfaceIndex {
                removeQueued(at: index)
                conflatedSurfaceCount += 1
            }
            pendingSurfaceIndex = queue.count
            queue.append(event)

        case .hingeChanged:
            // Only the current angle matters, so a consumer behind a fold in
            // progress sees where the hinge ended up rather than every degree
            // it passed through. The device samples at 10 Hz, so an unconflated
            // slot would grow for as long as someone keeps dragging.
            if let index = pendingHingeIndex {
                removeQueued(at: index)
            }
            pendingHingeIndex = queue.count
            queue.append(event)

        case .stateChanged, .orientationChanged:
            queue.append(event)
            noteTerminal(event)
        }
    }

    /// Close the channel to further sends, leaving whatever is queued
    /// readable.
    ///
    /// Teardown paths unsubscribe and *then* read what the pane published, so
    /// discarding here would lose the pane's own final events, terminal state
    /// included.
    func finish() {
        guard !finished else { return }
        finished = true
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }

    /// The next event, or nil once the channel is finished and drained.
    ///
    /// Returns synchronously whenever something is queued. `park` is reached
    /// only with an empty queue, and the continuation is stored without an
    /// intervening suspension, so a `send` racing this cannot be lost.
    func take() -> PaneEvent? {
        guard !queue.isEmpty else { return nil }
        let event = queue.removeFirst()
        shiftSlotsAfterRemoval(at: 0)
        return event
    }

    func park(_ continuation: CheckedContinuation<PaneEvent?, Never>) {
        waiter = continuation
    }

    /// Drop the queued entry at `index` and keep both conflatable slots
    /// pointing at the events they named.
    ///
    /// There are two such slots now, and they sit at independent positions, so
    /// a removal for one shifts the other whenever it sat further back. Doing
    /// this arithmetic at each removal site is what would leave a stale index
    /// pointing at a neighbour's event, and conflation would then drop the
    /// wrong one.
    private func removeQueued(at index: Int) {
        queue.remove(at: index)
        shiftSlotsAfterRemoval(at: index)
    }

    /// Re-point both slots after the entry at `index` has already been removed.
    private func shiftSlotsAfterRemoval(at index: Int) {
        pendingSurfaceIndex = shifted(pendingSurfaceIndex, afterRemovalAt: index)
        pendingHingeIndex = shifted(pendingHingeIndex, afterRemovalAt: index)
    }

    /// Where `slot` lands once the entry at `removed` is gone: nil when it was
    /// that entry, one earlier when it sat behind it, unchanged otherwise.
    private func shifted(_ slot: Int?, afterRemovalAt removed: Int) -> Int? {
        guard let slot else { return nil }
        if slot == removed { return nil }
        return slot > removed ? slot - 1 : slot
    }

    /// A terminal state seals the conflatable slot and discards any surface
    /// notice still pending, so no frame can be delivered after it. Lifecycle
    /// and orientation events are still accepted.
    private func noteTerminal(_ event: PaneEvent) {
        guard case let .stateChanged(_, state) = event else { return }
        switch state {
        case .shutdown, .failed:
            sealed = true
            if let index = pendingSurfaceIndex {
                removeQueued(at: index)
                conflatedSurfaceCount += 1
            }

        case .booting, .rendering:
            break
        }
    }
}
