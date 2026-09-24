// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

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
    /// When the current run was last observed alive. Zero if it never was,
    /// which is how a run that never happened measures as a zero-length run.
    /// Cleared at the start of each attempt, so it measures one run only.
    var lastSeenRunningAtNanos: UInt64 = 0
    /// When the program was last observed alive at all, across every
    /// attempt. Never cleared.
    ///
    /// Separate from the per-run reading because `status` reports it: a
    /// program that ran for a week and now cannot start still has an answer
    /// to "when was it last alive", and taking that from the current
    /// attempt's clock would throw it away at the worst moment.
    var lastAliveAtNanos: UInt64 = 0
    /// Exit history feeding the backoff and the give-up cap. Its count
    /// resets on a long run, so it is not what `restarts` reports.
    var history = AutomationRestartDecision.History()
    /// How many times the program has been started again since launch,
    /// whether by re-sending into its terminal or by opening a fresh tab
    /// for it. Never reset, unlike the consecutive-exit count, because a
    /// caller asking how much a program has flapped wants the lifetime
    /// figure.
    var restarts = 0
    /// Why the entry is not running, when there is something to say.
    var lastError: String?
    /// While `.restarting`, the clock reading at which the command is re-sent.
    var resumeAtNanos: UInt64 = 0
    /// Someone asked for a restart while the terminal was busy, so the
    /// command is owed as soon as it goes idle.
    ///
    /// Carries the request across ticks because the foreground can outlive
    /// several of them, and because it must survive `restart false`: an
    /// entry that opted out of automatic restarts was still restarted by
    /// hand, and that is a different instruction.
    var pendingRestart = false
}
