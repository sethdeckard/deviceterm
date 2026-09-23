// SPDX-License-Identifier: GPL-3.0-or-later

/// What supervision is holding about one configured program right now.
///
/// Keyed by entry name, which the file guarantees is unique.
///
/// The three clock readings are what make supervision level-triggered rather
/// than edge-triggered: nothing depends on catching the moment a program
/// exits, only on comparing "when was the command typed", "when was it last
/// seen alive", and "what time is it".
struct AutomationProgramRuntime: Equatable, Sendable {
    var state: AutomationProgramState = .starting
    /// The tab the program was launched into, or nil when no tab opened.
    var tabId: TabID?
    /// The terminal pane the command was typed into. Held so a restart
    /// cannot land in a sibling pane after this one goes away.
    var terminal: TerminalPaneID?
    /// The program's pid while it is running, nil otherwise.
    var pid: Int32?
    /// When the most recent send was attempted, on the caller's clock. Zero
    /// until one has been, which is why a tab still waiting for its grant is
    /// never mistaken for a program that exited.
    var commandSentAtNanos: UInt64 = 0
    /// When the program was last observed alive. Zero if it never was, which
    /// is how a run that never happened measures as a zero-length run.
    var lastSeenRunningAtNanos: UInt64 = 0
    /// Exit history feeding the backoff and the give-up cap.
    var history = AutomationRestartDecision.History()
    /// While `.restarting`, the clock reading at which the command is re-sent.
    var resumeAtNanos: UInt64 = 0
}
