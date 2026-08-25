// SPDX-License-Identifier: GPL-3.0-or-later

/// Inputs that move a pending pane between phases.
enum PendingPaneEvent: Equatable, Sendable {
    /// The attach RPC threw; carry the message for the error overlay.
    case attachFailed(String)
    /// The user hit Retry; a fresh attach is being spawned.
    case retried
}
