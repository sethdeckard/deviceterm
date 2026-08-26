// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Narrow role protocol for the daemon's
/// `app.commands` back-channel, the GUI's read-side of the tab/pane/
/// window verbs the CLI invokes.
///
/// Naming convention follows the other role protocols
/// (`SessionControlling`, `DeviceControlling`, `PaneControlling`,
/// `PaneSubscribing`); see those for the rationale. The
/// `AppCommandSubscriber` depends only on this; tests inject a fake
/// without dragging in the full DaemonClient surface.
@MainActor
protocol AppCommandControlling: AnyObject {
    /// Open the long-lived `app.commands` subscription. Yields one
    /// `(method, paramsData)` tuple per published `AppCommand`; the
    /// subscriber decodes the wire frame. `initial` is the daemon's
    /// ack on subscription setup. Stream finishes on transport
    /// errors or daemon-side disconnect.
    func subscribeAppCommands() async throws
    -> (initial: Data, events: AsyncStream<(String, Data)>)

    /// Send `app.commandResult` carrying the GUI's reply for one
    /// previously-published command. The daemon's coordinator routes
    /// it to the awaiting handler by `commandId`. Fire-and-forget on
    /// the GUI side; transport errors throw.
    func sendAppCommandResult(_ result: AppCommandResult) async throws
}
