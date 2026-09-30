// SPDX-License-Identifier: GPL-3.0-or-later

/// A pending pane's view-facing phase.
enum PendingPanePhase: Equatable, Sendable {
    /// The attach RPC is in flight, so show a spinner.
    case attaching
    /// The attach threw, so show the message + a Retry button.
    case failed(String)
    /// The attach was refused because the simulator is not booted, so show
    /// the daemon's message + a Boot button. Retry would be refused again.
    case notBooted(String)
    /// The user asked to boot the simulator and the boot is in flight.
    case booting

    /// Whether an attach has finished without a pane and nothing is running,
    /// so a new attach request should re-run this placeholder's attach rather
    /// than stack a second one.
    var isSettledFailure: Bool {
        switch self {
        case .failed, .notBooted:
            return true

        case .attaching, .booting:
            return false
        }
    }
}
