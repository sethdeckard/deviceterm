// SPDX-License-Identifier: GPL-3.0-or-later

/// A pending pane's view-facing phase.
enum PendingPanePhase: Equatable, Sendable {
    /// The attach RPC is in flight, so show a spinner.
    case attaching
    /// The attach threw, so show the message + a Retry button.
    case failed(String)
}
