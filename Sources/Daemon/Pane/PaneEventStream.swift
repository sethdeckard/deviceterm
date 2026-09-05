// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A subscriber's view of its `ConflatingEventChannel`.
///
/// Pull-based on purpose. The channel it reads is the only producer-side
/// pane-event buffer before transport delivery, so a consumer that stops asking
/// makes events pile up in the one place that conflates them. An `AsyncStream` in between would
/// reintroduce an unbounded queue, because a stream's continuation accepts
/// every yield whatever the consumer is doing.
///
/// How far that reaches depends on the transport. UDS awaits its framed writer,
/// so a slow client really does stop the pulls. XPC hands each envelope to
/// `xpc_connection_send_message`, which returns once libxpc has taken it, so
/// this bounds the daemon's own event lane and says nothing about libxpc's
/// outbound queue; the acknowledged surface pool is what bounds that.
struct PaneEventStream: AsyncSequence, Sendable {
    typealias Element = PaneEvent

    struct AsyncIterator: AsyncIteratorProtocol {
        let coordinator: PaneCoordinator
        let channel: ConflatingEventChannel

        mutating func next() async -> PaneEvent? {
            await coordinator.nextEvent(from: channel)
        }
    }

    let coordinator: PaneCoordinator
    /// Named directly rather than looked up per read. A reader outlives its
    /// subscriber record on the teardown paths that unsubscribe and then drain,
    /// and a lookup would answer nil there and swallow the pane's last events.
    let channel: ConflatingEventChannel

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(coordinator: coordinator, channel: channel)
    }
}
