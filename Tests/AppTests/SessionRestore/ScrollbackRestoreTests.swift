// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import Testing

private func tempDirectory() -> String {
    (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("deviceterm-scrollback-\(UUID().uuidString)/scrollback")
}

private func cleanUp(_ store: ScrollbackStore) {
    try? FileManager.default.removeItem(atPath: (store.directory as NSString).deletingLastPathComponent)
}

@Suite
struct ScrollbackReplayTests {
    @Test
    func endsRowsWithCRLFAndAppendsTheMarker() {
        #expect(
            ScrollbackReplay.output(from: "one\ntwo")
                == "one\r\ntwo\u{1B}[0m\r\n" + ScrollbackReplay.marker + "\r\n"
        )
    }

    @Test
    func keepsStyling() {
        let output = ScrollbackReplay.output(from: "\u{1B}[31mred\u{1B}[0m")
        #expect(output?.hasPrefix("\u{1B}[31mred\u{1B}[0m\u{1B}[0m\r\n") == true)
    }

    @Test
    func dropsTrailingBlankRowsIncludingStyledOnes() {
        #expect(
            ScrollbackReplay.output(from: "text\n\n   \n\u{1B}[0m  \n")
                == "text\u{1B}[0m\r\n" + ScrollbackReplay.marker + "\r\n"
        )
    }

    @Test("nothing to show restores no scrollback", arguments: ["", "\n\n", "  \n\u{1B}[0m"])
    func showsNothingForBlankHistory(saved: String) {
        #expect(ScrollbackReplay.output(from: saved) == nil)
    }
}

@Suite
struct ScrollbackStoreTests {
    @Test
    func writesThenReadsBack() throws {
        let store = ScrollbackStore(directory: tempDirectory())
        defer { cleanUp(store) }
        let id = try #require(store.write("\u{1B}[1mhello\u{1B}[0m\nworld"))
        #expect(UUID(uuidString: id) != nil)
        #expect(store.read(id) == "\u{1B}[1mhello\u{1B}[0m\nworld")
    }

    @Test
    func keepsFilesPrivate() throws {
        let store = ScrollbackStore(directory: tempDirectory())
        defer { cleanUp(store) }
        let id = try #require(store.write("secret"))
        let directory = try FileManager.default.attributesOfItem(atPath: store.directory)
        let file = try FileManager.default.attributesOfItem(
            atPath: (store.directory as NSString).appendingPathComponent("\(id).vt")
        )
        #expect((directory[.posixPermissions] as? Int) == 0o700)
        #expect((file[.posixPermissions] as? Int) == 0o600)
    }

    @Test("an id that isn't a UUID names no file", arguments: ["../../etc/passwd", "", "not-a-uuid"])
    func refusesIdsThatAreNotUUIDs(id: String) {
        #expect(ScrollbackStore(directory: tempDirectory()).read(id) == nil)
    }

    @Test
    func refusesAnOversizedFile() throws {
        let store = ScrollbackStore(directory: tempDirectory())
        defer { cleanUp(store) }
        let id = try #require(store.write("small"))
        let path = (store.directory as NSString).appendingPathComponent("\(id).vt")
        try Data(count: ScrollbackStore.maxBytes + 1).write(to: URL(fileURLWithPath: path))
        #expect(store.read(id) == nil)
    }

    @Test
    func removesEverythingButWhatIsKept() throws {
        let store = ScrollbackStore(directory: tempDirectory())
        defer { cleanUp(store) }
        let kept = try #require(store.write("kept"))
        let dropped = try #require(store.write("dropped"))
        store.removeAll(except: [kept])
        #expect(store.read(kept) == "kept")
        #expect(store.read(dropped) == nil)
        store.removeDirectory()
        #expect(!FileManager.default.fileExists(atPath: store.directory))
    }

    @Test
    func replaysEachTerminalTheSnapshotNames() throws {
        let store = ScrollbackStore(directory: tempDirectory())
        defer { cleanUp(store) }
        let saved = try #require(store.write("history"))
        let blank = try #require(store.write("\n\n"))
        let layout = WorkspaceSnapshot.Node.split(
            axis: .horizontal,
            children: [
                .terminal(.init(cwd: nil, name: nil, scrollback: saved)),
                .terminal(.init(cwd: nil, name: nil, scrollback: blank)),
                .terminal(.init(cwd: nil, name: nil, scrollback: UUID().uuidString)),
                .terminal(.init())
            ],
            ratios: nil
        )
        let snapshot = WorkspaceSnapshot(
            windows: [.init(frame: nil, tabs: [.init(title: nil, isPinned: false, layout: layout)], selectedTab: 0)],
            selectedWindow: 0
        )
        #expect(store.replayOutputs(for: snapshot) == [saved: ScrollbackReplay.output(from: "history")])
    }

    @Test
    func eachCheckoutBuildKeepsItsOwnDirectory() {
        let installed = ScrollbackStore.defaultDirectory(
            executablePath: "/Applications/DeviceTerm.app/Contents/MacOS/deviceterm",
            environment: ["XDG_STATE_HOME": "/tmp/state"]
        )
        let checkout = ScrollbackStore.defaultDirectory(
            executablePath: "/src/deviceterm/.build/debug/DeviceTerm.app/Contents/MacOS/deviceterm",
            environment: ["XDG_STATE_HOME": "/tmp/state"]
        )
        #expect(installed == "/tmp/state/deviceterm/scrollback")
        let workspace = WorkspaceSnapshotStore.fileName(
            executablePath: "/src/deviceterm/.build/debug/DeviceTerm.app/Contents/MacOS/deviceterm"
        )
        // The directory carries the same checkout suffix as the workspace file.
        let suffix = String(workspace.dropFirst("workspace".count).dropLast(".json".count))
        #expect(checkout == "/tmp/state/deviceterm/scrollback\(suffix)")
        #expect(!suffix.isEmpty)
    }
}

@Suite
struct ScrollbackRestorePolicyTests {
    @Test
    func defaultsToOff() {
        #expect(ScrollbackRestorePolicy.defaultPolicy == .off)
        #expect(ScrollbackRestorePolicy.resolve(nil) == .off)
        #expect(ScrollbackRestorePolicy.resolve("bogus") == .off)
        #expect(ScrollbackRestorePolicy.resolve("on") == .on)
    }

    @Test
    func readsOnFromAHandEditedConfig() throws {
        let url = try #require(Bundle.module.url(forResource: "restore-scrollback-on", withExtension: "config"))
        let config = ConfigFile(path: url.path)
        #expect(ScrollbackRestorePolicy.resolve(config.value(forKey: ScrollbackRestorePolicy.configKey)) == .on)
        #expect(
            DeviceTermConfigDefaults.spec(for: ScrollbackRestorePolicy.configKey)?.allowedValues == ["off", "on"]
        )
    }
}

@MainActor
@Suite
struct ScrollbackRouterRestoreTests {
    @Test
    func aTerminalWithSavedScrollbackStartsWithItsReplay() async throws {
        let fake = FakeDaemonClient()
        let workspace = WorkspaceViewModel()
        let router = Router(workspace: workspace, daemon: fake, detectWorktreeName: { nil })
        let layout = WorkspaceSnapshot.Node.split(
            axis: .horizontal,
            children: [
                .terminal(.init(cwd: nil, name: nil, scrollback: "A")),
                .terminal(.init(cwd: nil, name: nil, scrollback: "missing")),
                .terminal(.init())
            ],
            ratios: nil
        )
        await router.dispatchAndWait(
            .restoreWorkspace(
                WorkspaceSnapshot(
                    windows: [
                        .init(frame: nil, tabs: [.init(title: nil, isPinned: false, layout: layout)], selectedTab: 0)
                    ],
                    selectedWindow: 0
                ),
                scrollback: ["A": "replayed"]
            )
        )
        let tab = try #require(workspace.windows.first?.tabs.tabs.first)
        #expect(tab.terminals.map(\.restoredOutput) == ["replayed", nil, nil])
    }

    @Test
    func theSnapshotRecordsEachTerminalsScrollbackId() {
        let tab = TabState(
            id: TabID(value: 1),
            terminals: [
                TerminalPaneState(id: TerminalPaneID(value: 1), sessionId: "S1", capability: "C1"),
                TerminalPaneState(id: TerminalPaneID(value: 2), sessionId: "S2", capability: "C2")
            ],
            simPanes: []
        )
        let list = TabListViewModel()
        list.append(tab)
        let workspace = WorkspaceViewModel()
        workspace.addWindow(WindowState(id: WindowID(value: 1), tabs: list))
        let snapshot = WorkspaceSnapshotBuilder.build(
            workspace: workspace,
            sources: WorkspaceSnapshotBuilder.Sources(
                windowFrame: { _ in nil },
                ratios: { _ in [:] },
                workingDirectory: { _, _ in nil },
                manualTitle: { _ in nil },
                scrollback: { _, id in id.value == 1 ? "saved-1" : nil }
            )
        )
        let leaves = WorkspaceRestoreLayout.leaves(snapshot.windows[0].tabs[0].layout)
        #expect(
            leaves == [
                .terminal(.init(cwd: nil, name: nil, scrollback: "saved-1")),
                .terminal(.init(cwd: nil, name: nil, scrollback: nil))
            ]
        )
    }
}
