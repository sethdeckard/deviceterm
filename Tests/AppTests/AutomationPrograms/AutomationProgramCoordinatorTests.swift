// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Testing

// AutomationProgramCoordinatorTests: the launch pass.
//
// The rule with the most riding on it is that nothing configured means
// nothing happens: no window, no tab, no dispatch of any kind. Everything
// else here is about one bad block never taking the others down with it.

private func entry(
    _ name: String,
    command: String = "run",
    cwd: String = "/tmp"
) -> AutomationProgramEntry {
    AutomationProgramEntry(name: name, command: [command], cwd: cwd)
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

/// Stands in for the workspace, the router, and the config file, so the
/// launch pass runs with no window server and no daemon.
@MainActor
private final class Harness {
    var entries: [AutomationProgramEntry] = []
    var defects: [AutomationProgramDefect] = []

    /// Nil makes `ensureWindow` fail, standing in for a workspace that
    /// could not produce a window.
    var window: WindowID? = WindowID(value: 1)
    /// Makes `openAutomationTab` fail, standing in for a refused open.
    var openSucceeds = true

    private(set) var ensureWindowCalls = 0
    private(set) var opened: [OpenedTab] = []
    private(set) var renamed: [RenamedTab] = []
    private var nextTab = 1

    var deps: AutomationProgramCoordinator.Dependencies {
        AutomationProgramCoordinator.Dependencies(
            loadEntries: { [self] in (entries, defects) },
            ensureWindow: { [self] in
                ensureWindowCalls += 1
                return window
            },
            openAutomationTab: { [self] window, cwd, command in
                opened.append(OpenedTab(window: window, cwd: cwd, command: command))
                guard openSucceeds else { return nil }
                nextTab += 1
                return TabID(value: nextTab)
            },
            renameTab: { [self] window, tab, name in
                renamed.append(RenamedTab(window: window, tab: tab, name: name))
            }
        )
    }

    func coordinator() -> AutomationProgramCoordinator {
        AutomationProgramCoordinator(deps)
    }
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
    #expect(harness.renamed.first?.tab == TabID(value: 2))
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
