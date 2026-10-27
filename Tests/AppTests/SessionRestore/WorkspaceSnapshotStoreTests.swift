// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import Testing

private func fixtureData(_ name: String, _ ext: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext))
    return try Data(contentsOf: url)
}

private func tempPath() -> String {
    (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("deviceterm-snapshot-\(UUID().uuidString)/workspace.json")
}

@Suite
struct WorkspaceSnapshotFormatTests {
    @Test
    func decodesTheVersionOneFixture() throws {
        let snapshot = try #require(WorkspaceSnapshotStore.decode(fixtureData("workspace-snapshot-v1", "json")))
        #expect(snapshot.selectedWindow == 0)
        let window = try #require(snapshot.windows.first)
        #expect(window.frame == WorkspaceSnapshot.Frame(x: 40, y: 60, width: 1_200, height: 900))
        #expect(window.selectedTab == 1)
        #expect(window.tabs.count == 2)
        let pinned = window.tabs[0]
        #expect(pinned.title == "Checkout")
        #expect(pinned.isPinned)
        #expect(pinned.focusedLeaf == 1)
        let sim = WorkspaceSnapshot.Device(
            id: "6F9619FF-8B86-D011-B42D-00C04FC964FF",
            displayName: "iPhone 17 Pro",
            name: "checkout",
            family: "iphone",
            sizePreset: "pointAccurate"
        )
        #expect(
            pinned.layout == .split(
                axis: .horizontal,
                children: [
                    .terminal(.init(cwd: "/tmp", name: nil)),
                    .split(
                        axis: .vertical,
                        children: [.sim(sim), .terminal(.init(cwd: nil, name: "logs"))],
                        ratios: [0.7, 0.3]
                    )
                ],
                ratios: [0.4, 0.6]
            )
        )
        #expect(window.tabs[1].layout == .terminal(.init(cwd: nil, name: nil)))
    }

    @Test
    func roundTripsThroughTheEncodedForm() throws {
        let snapshot = try #require(WorkspaceSnapshotStore.decode(fixtureData("workspace-snapshot-v1", "json")))
        let encoded = try WorkspaceSnapshotStore.encode(snapshot)
        #expect(WorkspaceSnapshotStore.decode(encoded) == snapshot)
        // Sorted keys: an unchanged layout encodes to identical bytes.
        #expect(try WorkspaceSnapshotStore.encode(snapshot) == encoded)
    }

    @Test
    func ignoresAnotherVersion() throws {
        var snapshot = try #require(WorkspaceSnapshotStore.decode(fixtureData("workspace-snapshot-v1", "json")))
        snapshot.version = WorkspaceSnapshot.currentVersion + 1
        #expect(WorkspaceSnapshotStore.decode(try WorkspaceSnapshotStore.encode(snapshot)) == nil)
    }

    @Test("malformed input reads as nothing to restore", arguments: [
        "",
        "not json",
        #"{"version":1}"#,
        #"{"version":1,"windows":[{"tabs":[{"isPinned":false,"layout":{"type":"bogus"}}]}]}"#
    ])
    func ignoresMalformedInput(text: String) {
        #expect(WorkspaceSnapshotStore.decode(Data(text.utf8)) == nil)
    }
}

@Suite
struct WorkspaceSnapshotStoreTests {
    @Test
    func readsNothingWhenTheFileIsMissing() {
        #expect(WorkspaceSnapshotStore(path: tempPath()).read() == nil)
    }

    @Test
    func writesThenReadsBack() throws {
        let store = WorkspaceSnapshotStore(path: tempPath())
        defer { try? FileManager.default.removeItem(atPath: (store.path as NSString).deletingLastPathComponent) }
        let snapshot = WorkspaceSnapshot(
            windows: [
                .init(
                    frame: nil,
                    tabs: [.init(title: nil, isPinned: false, layout: .terminal(.init()))],
                    selectedTab: 0
                )
            ],
            selectedWindow: 0
        )
        store.write(try WorkspaceSnapshotStore.encode(snapshot))
        #expect(store.read() == snapshot)
    }

    @Test
    func readsNothingFromACorruptFile() {
        let store = WorkspaceSnapshotStore(path: tempPath())
        defer { try? FileManager.default.removeItem(atPath: (store.path as NSString).deletingLastPathComponent) }
        store.write(Data("{ truncated".utf8))
        #expect(store.read() == nil)
    }

    @Test
    func anInstalledAppUsesTheSharedFile() {
        #expect(
            WorkspaceSnapshotStore.fileName(
                executablePath: "/Applications/DeviceTerm.app/Contents/MacOS/deviceterm"
            ) == "workspace.json"
        )
        #expect(WorkspaceSnapshotStore.fileName(executablePath: nil) == "workspace.json")
    }

    @Test
    func eachCheckoutBuildGetsItsOwnFile() {
        let main = WorkspaceSnapshotStore.fileName(
            executablePath: "/src/deviceterm/.build/debug/DeviceTerm.app/Contents/MacOS/deviceterm"
        )
        let release = WorkspaceSnapshotStore.fileName(
            executablePath: "/src/deviceterm/.build/release/DeviceTerm.app/Contents/MacOS/deviceterm"
        )
        let worktree = WorkspaceSnapshotStore.fileName(
            executablePath: "/src/deviceterm.topic/.build/debug/DeviceTerm.app/Contents/MacOS/deviceterm"
        )
        #expect(main.hasPrefix("workspace-") && main.hasSuffix(".json"))
        #expect(main != "workspace.json")
        // Named for the checkout, not the configuration.
        #expect(main == release)
        #expect(main != worktree)
    }

    @Test
    func defaultPathLivesUnderTheStateHome() {
        let path = WorkspaceSnapshotStore.defaultPath(
            executablePath: "/Applications/DeviceTerm.app/Contents/MacOS/deviceterm",
            environment: ["XDG_STATE_HOME": "/tmp/state"]
        )
        #expect(path == "/tmp/state/deviceterm/workspace.json")
    }
}

@Suite
struct SessionRestorePolicyTests {
    @Test
    func defaultsToOn() {
        #expect(SessionRestorePolicy.defaultPolicy == .on)
        #expect(SessionRestorePolicy.resolve(nil) == .on)
        #expect(SessionRestorePolicy.resolve("bogus") == .on)
        #expect(SessionRestorePolicy.resolve("off") == .off)
    }

    @Test
    func readsOffFromAHandEditedConfig() throws {
        let url = try #require(Bundle.module.url(forResource: "restore-session-off", withExtension: "config"))
        let config = ConfigFile(path: url.path)
        #expect(
            SessionRestorePolicy.resolve(config.value(forKey: SessionRestorePolicy.configKey)) == .off
        )
        #expect(DeviceTermConfigDefaults.spec(for: SessionRestorePolicy.configKey)?.allowedValues == ["on", "off"])
    }
}

@Suite
struct RestoredWindowFrameDecisionTests {
    private let screen = CGRect(x: 0, y: 0, width: 1_440, height: 900)
    private let minSize = CGSize(width: 800, height: 500)

    @Test
    func keepsAFrameOnAnAttachedScreen() {
        let saved = CGRect(x: 100, y: 50, width: 1_000, height: 700)
        #expect(
            RestoredWindowFrameDecision.frame(saved: saved, visibleScreenFrames: [screen], minSize: minSize)
                == saved
        )
    }

    @Test
    func dropsAFrameOnADisplayThatIsGone() {
        let saved = CGRect(x: 3_000, y: 50, width: 1_000, height: 700)
        #expect(
            RestoredWindowFrameDecision.frame(saved: saved, visibleScreenFrames: [screen], minSize: minSize)
                == nil
        )
    }

    @Test
    func dropsAFrameBarelyOnScreen() {
        let saved = CGRect(x: 1_400, y: 50, width: 1_000, height: 700)
        #expect(
            RestoredWindowFrameDecision.frame(saved: saved, visibleScreenFrames: [screen], minSize: minSize)
                == nil
        )
    }

    @Test
    func dropsAFrameWhoseTitleBarIsAboveTheScreen() {
        // The lower part overlaps plenty; the top edge, where the title bar
        // is, sits above the screen.
        let saved = CGRect(x: 100, y: 600, width: 1_000, height: 700)
        #expect(
            RestoredWindowFrameDecision.frame(saved: saved, visibleScreenFrames: [screen], minSize: minSize)
                == nil
        )
    }

    @Test
    func keepsAFrameWhoseTitleBarIsOnASecondScreen() {
        let upper = CGRect(x: 0, y: 900, width: 1_440, height: 900)
        let saved = CGRect(x: 100, y: 600, width: 1_000, height: 700)
        #expect(
            RestoredWindowFrameDecision.frame(saved: saved, visibleScreenFrames: [screen, upper], minSize: minSize)
                == saved
        )
    }

    @Test
    func growsAFrameBelowTheMinimum() {
        let saved = CGRect(x: 100, y: 50, width: 200, height: 100)
        #expect(
            RestoredWindowFrameDecision.frame(saved: saved, visibleScreenFrames: [screen], minSize: minSize)
                == CGRect(x: 100, y: 50, width: 800, height: 500)
        )
    }

    @Test
    func dropsANonFiniteFrame() {
        let saved = CGRect(x: CGFloat.infinity, y: 50, width: 1_000, height: 700)
        #expect(
            RestoredWindowFrameDecision.frame(saved: saved, visibleScreenFrames: [screen], minSize: minSize)
                == nil
        )
    }
}
