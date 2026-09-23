// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Testing

// AutomationProgramCoordinatorTests: the launch pass and the supervision
// loop.
//
// The rule with the most riding on it is that nothing configured means
// nothing happens: no window, no tab, no dispatch of any kind. After that it
// is about a program's absence being read correctly. A program that has not
// started yet looks exactly like one that exited, and only the difference
// between them keeps a tab's normal startup gap from spending the whole
// restart budget before the program ever ran.

private let second: UInt64 = 1_000_000_000
/// The pid the terminal's foreground takes while the program runs.
private let programPid: Int32 = 910
/// The pid of the tab's own shell, which the foreground returns to whenever
/// nothing is running.
private let shellPid: Int32 = 900

private func entry(
    _ name: String,
    command: String = "run",
    cwd: String = "/tmp",
    restart: Bool = true
) -> AutomationProgramEntry {
    AutomationProgramEntry(name: name, command: [command], cwd: cwd, restart: restart)
}

private struct OpenedTab: Equatable {
    let window: WindowID
    let cwd: String
    let command: [String]
}

private struct RenamedTab: Equatable {
    let window: WindowID
    let tab: TabID
    let name: String
}

/// Drives the supervision loop without real time: each sleep spends one tick
/// of a fixed budget and advances the clock, and running out of ticks ends
/// the loop the same way a cancellation would.
///
/// Unchecked because the sleep seam is `@Sendable` while everything that
/// touches this runs on the main actor in practice, matching `WaitTestClock`
/// in the CLI tests.
private final class TickGate: @unchecked Sendable {
    private(set) var now: UInt64 = 0
    private var remaining: Int

    init(ticks: Int) { remaining = ticks }

    func sleep(_ nanos: UInt64) -> Bool {
        guard remaining > 0 else { return false }
        remaining -= 1
        now += nanos
        return true
    }
}

/// Stands in for the workspace, the router, the terminal, and the config
/// file, so both the launch pass and supervision run with no window server
/// and no daemon.
@MainActor
private final class Harness {
    var entries: [AutomationProgramEntry] = []
    var defects: [AutomationProgramDefect] = []

    /// Nil makes `ensureWindow` fail, standing in for a workspace that could
    /// not produce a window.
    var window: WindowID? = WindowID(value: 1)
    /// Makes `openAutomationTab` fail, standing in for a refused open.
    var openSucceeds = true
    /// False makes `locateTerminal` answer nil, standing in for a closed pane.
    var tabExists = true
    /// False makes the terminal unreadable, modelling a foreground process
    /// deviceterm cannot see across the uid boundary.
    var terminalReadable = true
    /// When true the program is seen running for exactly one observation
    /// after each start, modelling one that exits immediately every time.
    var exitsImmediately = false
    /// When set, the program is seen running on every observation.
    var staysRunning = false

    private(set) var ensureWindowCalls = 0
    private(set) var opened: [OpenedTab] = []
    private(set) var renamed: [RenamedTab] = []
    private(set) var sent: [String] = []
    private(set) var notices: [[String]] = []
    /// Fires as each tab opens, so a test can quit mid-launch.
    var onOpen: (@MainActor () -> Void)?
    private var nextTab = 1
    private var observationsSinceStart = 0
    /// Stands in for the tab typing the command once its grant applies.
    /// Nil models a tab still waiting, which must never read as an exit.
    var commandSentAt: UInt64?

    let gate: TickGate

    var deps: AutomationProgramCoordinator.Dependencies {
        AutomationProgramCoordinator.Dependencies(
            loadEntries: { [self] in (entries, defects) },
            ensureWindow: { [self] in
                ensureWindowCalls += 1
                return window
            },
            openAutomationTab: { [self] window, cwd, command in
                opened.append(OpenedTab(window: window, cwd: cwd, command: command))
                onOpen?()
                guard openSucceeds else { return nil }
                nextTab += 1
                return TabID(value: nextTab)
            },
            renameTab: { [self] window, tab, name in
                renamed.append(RenamedTab(window: window, tab: tab, name: name))
            },
            primaryTerminal: { _ in TerminalPaneID(value: 1) },
            locateTerminal: { [self] _, _ in tabExists ? window : nil },
            // Production records the LAUNCH send only and never updates it,
            // so the harness must not either. Keeping it fixed is what lets
            // a restart's own timestamp being overwritten by it be detected.
            commandSentAt: { [self] _ in commandSentAt },
            sendInput: { [self] _, _, _, text in
                sent.append(text)
                observationsSinceStart = 0
            },
            probe: AutomationProgramProbe(
                // The foreground process is the shell when idle and the
                // program when one is running, which is the real relationship
                // `TerminalShellIdentity` resolves in production.
                terminalIdentity: { [self] _ in
                    terminalReadable
                        ? (foregroundPid: currentPid() ?? shellPid, ttyName: "/dev/ttys001")
                        : nil
                },
                foregroundState: { foreground, _ in
                    foreground == shellPid ? .idle : .running(foreground)
                }
            ),
            presentFailureNotice: { [self] _, names in notices.append(names) },
            now: { [self] in gate.now },
            sleep: { [gate] nanos in gate.sleep(nanos) }
        )
    }

    init(ticks: Int = 8) { gate = TickGate(ticks: ticks) }

    private func currentPid() -> Int32? {
        if staysRunning { return programPid }
        guard exitsImmediately else { return nil }
        observationsSinceStart += 1
        return observationsSinceStart == 1 ? programPid : nil
    }

    func coordinator() -> AutomationProgramCoordinator {
        AutomationProgramCoordinator(deps)
    }
}

/// Give the supervision loop room to spend its tick budget. Bounded yielding
/// rather than a wait on completion: the loop exposes no completion to await,
/// so this is a ceiling on how much it can run, not a guarantee that it has.
@MainActor
private func settle() async {
    for _ in 0..<5_000 { await Task.yield() }
}

// MARK: - Nothing configured

/// The whole of acceptance for an unconfigured install: the feature is
/// indistinguishable from not existing.
@Test("nothing configured dispatches nothing at all")
@MainActor
func noEntriesDispatchesNothing() async {
    let harness = Harness()
    await harness.coordinator().start()
    #expect(harness.ensureWindowCalls == 0)
    #expect(harness.opened.isEmpty)
    #expect(harness.renamed.isEmpty)
    #expect(harness.sent.isEmpty)
}

@Test("a file with only defects opens no tab")
@MainActor
func defectsOnlyDispatchesNothing() async {
    let harness = Harness()
    harness.defects = [
        AutomationProgramDefect(name: "p", line: 1, reason: .missingCommand)
    ]
    await harness.coordinator().start()
    #expect(harness.opened.isEmpty)
}

// MARK: - Opening tabs

@Test("each program gets a tab carrying its command and cwd")
@MainActor
func opensATabPerProgram() async {
    let harness = Harness()
    harness.entries = [
        entry("first", command: "run-a", cwd: "/a"),
        entry("second", command: "run-b", cwd: "/b")
    ]
    await harness.coordinator().start()
    #expect(harness.opened.map(\.cwd) == ["/a", "/b"])
    #expect(harness.opened.map(\.command) == [["run-a"], ["run-b"]])
}

/// Tabs open in the order the file lists them, which is the part deviceterm
/// controls. When each program starts depends on when its tab's grant
/// applies.
@Test("tabs open in file order")
@MainActor
func opensInFileOrder() async {
    let harness = Harness()
    harness.entries = [entry("first"), entry("second"), entry("third")]
    await harness.coordinator().start()
    #expect(harness.renamed.map(\.name) == ["first", "second", "third"])
}

@Test("each tab is titled with its program's name")
@MainActor
func titlesEachTab() async {
    let harness = Harness()
    harness.entries = [entry("build-bridge")]
    await harness.coordinator().start()
    #expect(harness.renamed.count == 1)
    #expect(harness.renamed.first?.name == "build-bridge")
}

// MARK: - Failures never cascade

@Test("a program whose tab will not open is skipped, not retried")
@MainActor
func skipsAnUnopenableTab() async {
    let harness = Harness()
    harness.openSucceeds = false
    harness.entries = [entry("p")]
    await harness.coordinator().start()
    #expect(harness.opened.count == 1)
    #expect(harness.renamed.isEmpty)
}

@Test("no window means no tabs and no rename")
@MainActor
func skipsWhenNoWindow() async {
    let harness = Harness()
    harness.window = nil
    harness.entries = [entry("p"), entry("q")]
    await harness.coordinator().start()
    #expect(harness.opened.isEmpty)
    #expect(harness.renamed.isEmpty)
}

// MARK: - Launch happens once

@Test("re-calling start opens nothing a second time")
@MainActor
func startIsIdempotent() async {
    let harness = Harness()
    harness.entries = [entry("p")]
    let coordinator = harness.coordinator()
    await coordinator.start()
    await coordinator.start()
    #expect(harness.opened.count == 1)
    #expect(harness.renamed.count == 1)
}

// MARK: - Supervision

/// The gap between a tab opening and its program appearing is ordinary: the
/// command waits for the grant and the shell has its own startup to do.
/// Reading that as an exit would spend the restart budget before the program
/// ever ran.
@Test("a program that has not started yet is not treated as having exited")
@MainActor
func startupGapIsNotAnExit() async {
    let harness = Harness(ticks: 6)
    harness.entries = [entry("p")]
    let coordinator = harness.coordinator()
    await coordinator.start()
    await settle()
    #expect(harness.sent.isEmpty)
    #expect(coordinator.runtimesForTesting["p"]?.state == .starting)
}

/// A program that dies between two polls is never observed running at all.
/// Edge-triggered supervision would sit waiting for an exit it already
/// missed; asking "should this be running, and is it" catches it.
@Test("a program that never appears at all is restarted")
@MainActor
func aProgramThatNeverAppearsIsRestarted() async {
    let harness = Harness(ticks: 20)
    harness.commandSentAt = 1
    harness.entries = [entry("p", command: "run-me")]
    let coordinator = harness.coordinator()
    await coordinator.start()
    await settle()
    #expect(harness.sent.first == "run-me\n")
}

/// An unreadable terminal is not an idle one. Typing into it could land in
/// a foreground process deviceterm cannot see, so the pass does nothing at
/// all: no restart, and no exit counted either.
@Test("an unreadable terminal is never typed into")
@MainActor
func anUnreadableTerminalIsNeverTypedInto() async {
    let harness = Harness(ticks: 20)
    harness.terminalReadable = false
    harness.commandSentAt = 1
    harness.entries = [entry("p")]
    let coordinator = harness.coordinator()
    await coordinator.start()
    await settle()
    #expect(harness.sent.isEmpty)
    #expect(coordinator.runtimesForTesting["p"]?.state == .starting)
}

/// A restart records its own send time, and the next pass must not replace it
/// with the tab's older launch time. If it did, the grace period would be
/// spent before the program could appear and every tick would count another
/// exit: over these twenty ticks that is three sends rather than two.
@Test("a restart gets its own grace period")
@MainActor
func aRestartGetsItsOwnGracePeriod() async {
    let harness = Harness(ticks: 20)
    harness.commandSentAt = 1
    harness.entries = [entry("p")]
    let coordinator = harness.coordinator()
    await coordinator.start()
    await settle()
    #expect(harness.sent.count == 2)
}

@Test("a program still running is left alone")
@MainActor
func leavesARunningProgramAlone() async {
    let harness = Harness(ticks: 6)
    harness.staysRunning = true
    harness.entries = [entry("p")]
    let coordinator = harness.coordinator()
    await coordinator.start()
    await settle()
    #expect(harness.sent.isEmpty)
    #expect(coordinator.runtimesForTesting["p"]?.state == .running)
    #expect(coordinator.runtimesForTesting["p"]?.pid == programPid)
}

@Test("a program that exits is re-run in the same tab")
@MainActor
func restartsAnExitedProgram() async {
    let harness = Harness(ticks: 20)
    harness.exitsImmediately = true
    harness.commandSentAt = 1
    harness.entries = [entry("p", command: "run-me")]
    let coordinator = harness.coordinator()
    await coordinator.start()
    await settle()
    #expect(harness.sent.first == "run-me\n")
    // Re-run in the tab it already has, never by opening a second one.
    #expect(harness.opened.count == 1)
}

/// One rule covers a confirmed close, a window close, a CLI close, and a
/// crash: the tab is gone, so supervision stops rather than reopening.
@Test("a closed tab stops supervision instead of reopening")
@MainActor
func aClosedTabStopsSupervision() async {
    let harness = Harness(ticks: 6)
    harness.staysRunning = true
    harness.entries = [entry("p")]
    let coordinator = harness.coordinator()
    await coordinator.start()
    harness.tabExists = false
    await settle()
    #expect(coordinator.runtimesForTesting["p"]?.state == .stopped)
    #expect(harness.sent.isEmpty)
    #expect(harness.opened.count == 1)
}

@Test("restart false stops the program instead of re-running it")
@MainActor
func restartFalseIsHonoured() async {
    let harness = Harness(ticks: 20)
    harness.exitsImmediately = true
    harness.commandSentAt = 1
    harness.entries = [entry("p", restart: false)]
    let coordinator = harness.coordinator()
    await coordinator.start()
    await settle()
    #expect(coordinator.runtimesForTesting["p"]?.state == .stopped)
    #expect(harness.sent.isEmpty)
}

/// Repeated short runs are capped rather than retried forever, and
/// supervision says so exactly once.
@Test("a program that keeps exiting is given up on, with one notice")
@MainActor
func givesUpAndNoticesOnce() async {
    let harness = Harness(ticks: 5_000)
    harness.exitsImmediately = true
    harness.commandSentAt = 1
    harness.entries = [entry("p")]
    let coordinator = harness.coordinator()
    await coordinator.start()
    await settle()
    #expect(coordinator.runtimesForTesting["p"]?.state == .failed)
    #expect(harness.notices == [["p"]])
    // Nine restarts, then the tenth exit gives up.
    #expect(harness.sent.count == AutomationRestartDecision.consecutiveExitCap - 1)
}

/// Opening a tab suspends, so quit can land between two entries. Cancelling
/// only the tick loop would let the rest of the launch pass keep opening tabs
/// and then start supervising them after the app was told to stop.
@Test("stop during the launch pass opens no further tabs")
@MainActor
func stopDuringLaunchOpensNoFurtherTabs() async {
    let harness = Harness(ticks: 20)
    harness.entries = [entry("first"), entry("second"), entry("third")]
    let coordinator = harness.coordinator()
    harness.onOpen = { [weak coordinator] in coordinator?.stop() }
    await coordinator.start()
    await settle()
    #expect(harness.opened.count == 1)
    #expect(harness.sent.isEmpty)
}

@Test("stop ends supervision")
@MainActor
func stopEndsSupervision() async {
    let harness = Harness(ticks: 5_000)
    harness.exitsImmediately = true
    harness.commandSentAt = 1
    harness.entries = [entry("p")]
    let coordinator = harness.coordinator()
    await coordinator.start()
    coordinator.stop()
    await settle()
    #expect(coordinator.runtimesForTesting["p"]?.state != .failed)
}
