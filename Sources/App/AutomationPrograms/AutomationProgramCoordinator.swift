// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import os

/// Opens an Automation tab per configured program at launch, runs its command
/// there, and keeps it running.
///
/// The feature's whole trust story is that this changes nothing about who
/// issues authority. The GUI opens the tab and the GUI issues the grant,
/// exactly as it does for Shell ▸ Open Automation Tab; `AutomationGrantCoordinator`
/// picks the tab up on terminal bind and needs no help from here, so there is
/// deliberately no grant code in this type. The only new input is a file the
/// user edits by hand, which already sits at the trust level of a shell rc
/// file.
///
/// **Nothing configured means nothing happens.** An absent file yields no
/// entries, and this dispatches nothing at all.
///
/// Supervision is one tick loop over every entry rather than a task each, so
/// the whole thing advances on a single injected clock and a single injected
/// sleep. Every seam is injected, so both the launch pass and the restart
/// rules are testable without a workspace, a daemon, or a window server.
@MainActor
final class AutomationProgramCoordinator {
    /// Injected seams, following `InventorySyncCoordinator.Dependencies`.
    struct Dependencies {
        /// Read the configured programs and whatever the file got wrong.
        var loadEntries: @MainActor () -> (
            entries: [AutomationProgramEntry],
            defects: [AutomationProgramDefect]
        )
        /// The window to open tabs in, creating one if the workspace has
        /// none. Nil when no window could be had.
        var ensureWindow: @MainActor () async -> WindowID?
        /// Open an Automation tab running `command` in `cwd`, and answer
        /// which tab it turned out to be. Nil when the open failed.
        var openAutomationTab: @MainActor (WindowID, String, [String]) async -> TabID?
        /// Title the tab with the program's name.
        var renameTab: @MainActor (WindowID, TabID, String) -> Void
        /// The terminal pane a freshly opened tab runs its command in.
        var primaryTerminal: @MainActor (TabID) -> TerminalPaneID?
        /// Where a supervised program's own terminal pane currently is, or
        /// nil once that pane is gone. Resolved by terminal rather than by
        /// tab, so a restart cannot land in a sibling pane.
        var locateTerminal: @MainActor (TabID, TerminalPaneID) -> WindowID?
        /// When the tab last attempted its configured command's first send,
        /// on the same clock as `now`, or nil before any attempt. The first run is typed by the
        /// tab itself once its grant applies, so supervision reads the time
        /// rather than being told.
        var commandSentAt: @MainActor (TabID) -> UInt64?
        /// Type text into a program's terminal, to re-run it after it exited.
        var sendInput: @MainActor (WindowID, TabID, TerminalPaneID, String) -> Void
        /// Whether a program is running in a tab, and under which pid.
        var probe: AutomationProgramProbe
        /// Say, once, that these programs have been given up on. The window
        /// is the one holding the last of them.
        var presentFailureNotice: @MainActor (WindowID, [String]) -> Void
        var now: @MainActor () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
        /// Cancellation-aware sleep; false means the loop should exit.
        var sleep: @Sendable (UInt64) async -> Bool
        /// How often supervision looks at each program.
        var pollIntervalNanoseconds: UInt64 = 1_000_000_000
        /// How long after the command is typed a program may take to appear
        /// in the terminal's foreground before its absence counts as an exit.
        /// The shell forks within milliseconds of reading the line, so this
        /// is slack rather than a real expectation.
        var startGraceNanoseconds: UInt64 = 5_000_000_000
    }

    /// Subsystem is the app's bundle identifier, matching the daemon's
    /// `com.deviceterm.daemon`. Configuration defects are reported only
    /// through this unified-log category.
    private let log = Logger(subsystem: "com.deviceterm", category: "automation-programs")

    private let deps: Dependencies
    private var hasStarted = false
    /// Set by `stop`. Checked between launches as well as around the tick
    /// loop, because the launch pass suspends on every tab it opens and quit
    /// can land in one of those gaps.
    private var isStopped = false
    /// Entries in file order, and their supervision state by name.
    private var entries: [AutomationProgramEntry] = []
    private var runtimes: [String: AutomationProgramRuntime] = [:]
    private var supervision: Task<Void, Never>?

    /// Test seam: the supervision state of each entry, by name.
    var runtimesForTesting: [String: AutomationProgramRuntime] { runtimes }

    private var hasSupervisableWork: Bool {
        runtimes.values.contains {
            switch $0.state {
            case .starting, .running, .restarting:
                return true

            case .stopped, .failed:
                return false
            }
        }
    }

    init(_ deps: Dependencies) {
        self.deps = deps
    }

    /// Run the launch pass once, then supervise what it opened.
    ///
    /// Tabs open sequentially so their order matches the file's. Re-calling
    /// is a no-op; launch happens once per run of the app.
    func start() async {
        guard !hasStarted, !isStopped else { return }
        hasStarted = true

        let (entries, defects) = deps.loadEntries()
        for defect in defects {
            // A defect never stops deviceterm from starting and never stops
            // the other programs from running, so this reports and moves on.
            log.error("automation-programs: \(defect.summary, privacy: .public)")
        }
        guard !entries.isEmpty else { return }
        self.entries = entries

        for entry in entries {
            // Opening a tab suspends, so quit can land between two entries.
            guard !isStopped else { return }
            let opened = await launch(entry)
            runtimes[entry.name] = AutomationProgramRuntime(
                tabId: opened?.tab,
                terminal: opened?.terminal
            )
        }
        guard !isStopped else { return }
        beginSupervising()
    }

    /// Stop opening tabs and stop supervising.
    ///
    /// Both halves matter at quit: cancelling the tick loop alone would let a
    /// launch pass still working through its entries open more tabs and then
    /// start supervising them after the app had been told to stop.
    ///
    /// Every suspension point the launch pass owns is checked, so no further
    /// tab is asked for. A tab whose open is already in flight still arrives,
    /// because that request has left and there is nothing here to recall it;
    /// nothing supervises it afterwards.
    func stop() {
        isStopped = true
        supervision?.cancel()
        supervision = nil
    }

    /// Open a tab for `entry` and title it, answering which tab and terminal
    /// pane that was.
    private func launch(
        _ entry: AutomationProgramEntry
    ) async -> (tab: TabID, terminal: TerminalPaneID)? {
        guard let windowID = await deps.ensureWindow() else {
            log.error(
                """
                automation-programs: no window to open \
                \(entry.name, privacy: .public) in
                """
            )
            return nil
        }
        // Getting a window suspends too, so re-check before opening: a quit
        // that landed during that wait must not still produce a tab.
        guard !isStopped else { return nil }
        guard let tabID = await deps.openAutomationTab(windowID, entry.cwd, entry.command) else {
            log.error(
                """
                automation-programs: could not open a tab for \
                \(entry.name, privacy: .public)
                """
            )
            return nil
        }
        deps.renameTab(windowID, tabID, entry.name)
        guard let terminal = deps.primaryTerminal(tabID) else { return nil }
        return (tabID, terminal)
    }

    private func beginSupervising() {
        guard supervision == nil, hasSupervisableWork else { return }
        supervision = Task { [weak self] in
            while let self, await self.hasWorkAfterSleeping() {
                self.tick()
            }
        }
    }

    /// Wait one poll interval, answering whether there is still anything to
    /// supervise. False ends the loop, which a cancelled sleep also does.
    private func hasWorkAfterSleeping() async -> Bool {
        guard hasSupervisableWork else { return false }
        let interval = deps.pollIntervalNanoseconds
        guard await deps.sleep(interval) else { return false }
        return !Task.isCancelled
    }

    /// Advance every entry by one observation.
    ///
    /// Level-triggered: nothing here depends on catching the instant a
    /// program exits. Each pass asks "should this be running, and is it",
    /// which answers a normal exit, an exit that fell between two polls, and
    /// a program that never started at all with the same code.
    private func tick() {
        var failures: [(window: WindowID, name: String)] = []
        for entry in entries {
            guard let runtime = runtimes[entry.name] else { continue }
            switch runtime.state {
            case .stopped, .failed:
                continue

            case .starting, .running, .restarting:
                if let failure = observe(entry) { failures.append(failure) }
            }
        }
        // One notice for the whole tick, so several programs giving up at
        // once do not stack notices on the same window.
        if let window = failures.last?.window {
            deps.presentFailureNotice(window, failures.map(\.name))
        }
    }

    /// Reconcile one program against what its terminal is actually running.
    /// Returns the entry when this pass gave up on it.
    private func observe(_ entry: AutomationProgramEntry) -> (window: WindowID, name: String)? {
        guard var runtime = runtimes[entry.name],
            let tabId = runtime.tabId,
            let terminal = runtime.terminal
        else { return nil }
        guard let window = deps.locateTerminal(tabId, terminal) else {
            // The pane is gone: the tab was closed, the window was closed,
            // or the shell itself exited and took the pane with it. All of
            // them mean the person is done with this program, so supervision
            // stops rather than fighting them. Relaunching deviceterm starts
            // the configured program again.
            runtime.state = .stopped
            runtime.pid = nil
            runtimes[entry.name] = runtime
            return nil
        }
        // The tab types the FIRST run itself, once its grant applies, so that
        // send time is read rather than assumed. Only the first: the tab
        // records the launch send and never updates it, so re-reading it
        // after a restart would replace the restart's own timestamp with an
        // older one and retire the grace period before the program could
        // appear.
        if runtime.commandSentAtNanos == 0, let launched = deps.commandSentAt(tabId) {
            runtime.commandSentAtNanos = launched
        }
        let now = deps.now()

        let terminalState = deps.probe.state(ofTab: tabId)
        if case .unknown = terminalState {
            // The kernel will not say what this terminal is running. Typing
            // into it could land in a foreground process deviceterm simply
            // cannot read, and counting an exit would be a guess, so this
            // pass does neither. A dead program's terminal returns to its own
            // shell, which is readable, so this resolves itself.
            runtimes[entry.name] = runtime
            return nil
        }

        if case let .running(pid) = terminalState {
            if runtime.state != .running {
                // Something is in the terminal's foreground. The probe reads
                // the foreground process, not which program it is, so an
                // editor opened during a backoff counts here too: supervision
                // leaves the terminal alone until it is idle again.
                runtime.state = .running
                runtime.history.startedAtNanos = now
            }
            runtime.pid = pid
            runtime.lastSeenRunningAtNanos = now
            runtimes[entry.name] = runtime
            return nil
        }

        runtime.pid = nil
        if runtime.state == .restarting {
            guard now >= runtime.resumeAtNanos else {
                runtimes[entry.name] = runtime
                return nil
            }
            // The latest observation found the shell in this terminal's
            // foreground. That is not prompt readiness, and the foreground
            // can change between the observation and these keystrokes, so it
            // narrows the window rather than closing it.
            deps.sendInput(window, tabId, terminal, entry.command.joined(separator: " ") + "\n")
            runtime.state = .starting
            runtime.commandSentAtNanos = now
            runtime.lastSeenRunningAtNanos = 0
            runtime.history.startedAtNanos = 0
            runtimes[entry.name] = runtime
            return nil
        }

        // Not running, and not waiting out a backoff. Either it exited or it
        // never arrived; both are the same event once the grace has passed.
        guard runtime.commandSentAtNanos > 0,
            now >= runtime.commandSentAtNanos + deps.startGraceNanoseconds
        else {
            runtimes[entry.name] = runtime
            return nil
        }
        // The run ended when it was last seen, not now. A run that never
        // happened measures zero, which is what makes a program that cannot
        // start reach the cap instead of retrying forever.
        switch AutomationRestartDecision.afterExit(
            history: runtime.history,
            restart: entry.restart,
            now: runtime.lastSeenRunningAtNanos
        ) {
        case let .restart(delay, history):
            runtime.state = .restarting
            runtime.history = history
            runtime.resumeAtNanos = now + delay
            runtimes[entry.name] = runtime
            return nil

        case .stop:
            runtime.state = .stopped
            runtimes[entry.name] = runtime
            return nil

        case .giveUp:
            runtime.state = .failed
            runtimes[entry.name] = runtime
            log.error(
                """
                automation-programs: giving up on \(entry.name, privacy: .public) \
                after \(AutomationRestartDecision.consecutiveExitCap, privacy: .public) \
                runs that each ended within a minute
                """
            )
            return (window, entry.name)
        }
    }
}
