// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Transport abstraction for establishing pane-event streams
/// independently of one-shot requests. A test injects a scripted subscribe
/// path to drive the reconnect re-authentication retry (`subscribePane`'s
/// -32001 retry) without a socket; production routes through the concrete
/// transport enum.
protocol DaemonSubscribeTransport: Sendable {
    func subscribePane(paneId: String) async throws -> AsyncStream<PaneEvent>
}
