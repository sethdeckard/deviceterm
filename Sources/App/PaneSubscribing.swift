// SPDX-License-Identifier: GPL-3.0-or-later
//
// Role protocol: pane event subscription on the daemon.
//
// One of four narrow role protocols carved out of `DaemonClient`
// (see `SessionControlling` for the rationale). `PaneEvent`
// stays App-internal (the decoded shape the GUI consumes); the wire
// frames behind it live in `DaemonClient`.

@MainActor
protocol PaneSubscribing: AnyObject {
    /// `pane.subscribe`. The returned stream finishes when the daemon
    /// ends the subscription (typically via `pane.close`).
    func subscribePane(paneId: String) async throws -> AsyncStream<PaneEvent>
}
