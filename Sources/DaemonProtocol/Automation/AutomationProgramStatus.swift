// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One configured automation program, as `deviceterm automation status`
/// reports it.
///
/// **No exit code.** A configured command runs inside its terminal's
/// shell, so deviceterm never reaps it and never receives its exit status.
/// What it has instead is what the terminal's foreground process was,
/// sampled, which is why `lastSeenRunning` is reported in its place.
public struct AutomationProgramStatus: Codable, Equatable, Sendable {
    /// The entry's name from the configuration file, which is also its tab
    /// title and the `--name` the restart verb takes.
    public let name: String
    public let state: AutomationProgramState
    /// The last observed non-shell foreground process id in the supervised
    /// terminal, absent when the terminal was its own shell. Not verified
    /// to be the configured command: anything the terminal is running,
    /// including something started by hand, reads the same way.
    public let pid: Int32?
    /// Public tab reference, absent when no tab was opened for this entry.
    public let tabId: String?
    /// Public pane reference for the terminal the command runs in.
    public let paneId: String?
    /// How many times supervision has re-run the command since launch.
    public let restarts: Int
    /// When that foreground observation was last made, ISO-8601. Absent
    /// when the terminal has never been seen running anything but its own
    /// shell, which is itself the answer to why a program that cannot start
    /// keeps being retried. Carries the same caveat as `pid`.
    public let lastSeenRunning: String?
    /// Why the entry is not running, when there is something to say.
    public let lastError: String?

    public init(
        name: String,
        state: AutomationProgramState,
        pid: Int32? = nil,
        tabId: String? = nil,
        paneId: String? = nil,
        restarts: Int = 0,
        lastSeenRunning: String? = nil,
        lastError: String? = nil
    ) {
        self.name = name
        self.state = state
        self.pid = pid
        self.tabId = tabId
        self.paneId = paneId
        self.restarts = restarts
        self.lastSeenRunning = lastSeenRunning
        self.lastError = lastError
    }
}
