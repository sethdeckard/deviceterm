// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// One subscriber's pending pane events, with surface notices conflated.
///
/// A pane publishes `surfaceChanged` at the display's rate and everything else
/// at the rate a user or a device produces it. A consumer that falls behind
/// therefore accumulates surface notices and almost nothing else, so this keeps
/// **at most one** pending surface notice per subscriber and lets lifecycle and
/// orientation events queue in full. Losing a `shutdown` to make room for a
/// frame notice would trade a bounded queue for a pane that never learns it
/// died.
///
/// The lossless queue has no cap. Its producers are lifecycle transitions and
/// rotations, which arrive at human rates; the 60Hz lane is the one that needed
/// bounding, and it is bounded at one. `EventBroker` is left unbounded for the
/// same reason.
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
                queue.remove(at: index)
                conflatedSurfaceCount += 1
            }
            pendingSurfaceIndex = queue.count
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
        switch pendingSurfaceIndex {
        case 0:
            pendingSurfaceIndex = nil

        case let .some(index):
            pendingSurfaceIndex = index - 1

        case nil:
            break
        }
        return event
    }

    func park(_ continuation: CheckedContinuation<PaneEvent?, Never>) {
        waiter = continuation
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
                queue.remove(at: index)
                pendingSurfaceIndex = nil
                conflatedSurfaceCount += 1
            }

        case .booting, .rendering:
            break
        }
    }
}
