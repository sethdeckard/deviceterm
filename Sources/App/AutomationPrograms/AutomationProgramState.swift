// SPDX-License-Identifier: GPL-3.0-or-later

/// Where supervision has got to with one configured program.
///
/// `starting` and `running` are distinguished because the probe cannot tell
/// "has not begun yet" from "has exited" on its own, and the gap between a
/// tab opening and its program appearing is entirely normal: the command
/// waits for the tab's grant, and the shell has its own startup to do.
/// Counting that gap as an exit would spend the whole restart budget before
/// the program ever ran.
enum AutomationProgramState: Equatable, Sendable {
    /// The tab is open and the program has not been seen running yet, either
    /// because it has not started or because it is between restarts.
    case starting
    /// Seen running, under a known pid.
    case running
    /// Exited, waiting out the backoff before being re-run.
    case restarting
    /// No longer supervised: the tab went away, or the program exited and the
    /// entry asked not to be restarted.
    case stopped
    /// Exited too many times in a row without a run long enough to count as
    /// working. Supervision has given up and said so.
    case failed
}
