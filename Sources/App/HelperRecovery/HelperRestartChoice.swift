// SPDX-License-Identifier: GPL-3.0-or-later

/// The user's answer.
enum HelperRestartChoice: Sendable, Equatable {
    case restart
    /// "Keep Waiting" on the unresponsive prompt: the user has judged the
    /// helper worth waiting for, so the detector stays quiet for a while
    /// rather than re-raising the same prompt on the next streak.
    case keepWaiting
    /// "Cancel" on the requested prompt: nothing to snooze, nothing changes.
    case cancel

    /// The value the recovery log records for this answer.
    var logLabel: String {
        switch self {
        case .restart:
            "restart"

        case .keepWaiting:
            "keepWaiting"

        case .cancel:
            "cancel"
        }
    }
}
