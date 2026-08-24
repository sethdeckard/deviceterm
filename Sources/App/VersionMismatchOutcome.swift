// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// The result of handling a definite daemon wire-version mismatch: the GUI tries
/// to stop the incompatible daemon (so the next launch doesn't reconnect to it)
/// before surfacing the user-facing remediation.
struct VersionMismatchOutcome: Sendable {
    /// The shutdown-request outcome. Deliberately NOT a "stopped" boolean: an
    /// acknowledgement proves the daemon *accepted* the request (termination is
    /// imminent, not necessarily already complete), and a lost ack is genuinely
    /// *unknown*: a transport drop can race an accepted shutdown. So the two
    /// honest states are "confirmed acceptance" and "indeterminate".
    enum Shutdown: Sendable {
        /// The daemon acknowledged the request: it accepted the shutdown.
        case confirmed
        /// No acknowledgement arrived (a transport loss that may or may not have
        /// raced an accepted shutdown, an explicit `{ok:false}`, or a transport
        /// that structurally can't request one). The daemon's state is unknown.
        case indeterminate(String)
    }

    let mismatch: DaemonClientError
    let shutdown: Shutdown
}
