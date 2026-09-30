// SPDX-License-Identifier: GPL-3.0-or-later

/// Inputs that move a pending pane between phases.
enum PendingPaneEvent: Equatable, Sendable {
    /// The attach RPC threw; carry the message for the error overlay.
    case attachFailed(String)
    /// The attach was refused because the simulator is not booted; carry the
    /// daemon's message, which names the device.
    case deviceNotBooted(String)
    /// The user hit Boot on a not-booted placeholder.
    case bootStarted
    /// A fresh attach is being spawned: the user hit Retry, or a boot was
    /// accepted.
    case retried
}
