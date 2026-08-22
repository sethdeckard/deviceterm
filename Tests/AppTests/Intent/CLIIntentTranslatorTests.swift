// SPDX-License-Identifier: GPL-3.0-or-later
//
// CLIIntentTranslatorTests: round-trip every `AppCommandKind` from
// the wire's `AppCommand` shape to the matching `RouteIntent`. Pure
// shape conversion; no dispatch / no resolver. A malformed params
// blob surfaces as `IntentError.internalError`, never as a silent
// degradation.

@testable import App
import DaemonProtocol
import Foundation
import Testing

struct CLIIntentTranslatorTests {
    // MARK: - Helpers

    private func makeCommand<Params: Encodable>(
        kind: AppCommandKind,
        params: Params,
        sessionId: String? = nil
    ) throws -> AppCommand {
        let bytes = try JSONEncoder().encode(params)
        return AppCommand(
            commandId: "cmd-\(kind.rawValue)",
            kind: kind,
            originatingSessionId: sessionId,
            params: bytes
        )
    }

    // MARK: - Tab verbs

    @Test
    func translatesTabOpenWithDefaults() throws {
        let cmd = try makeCommand(
            kind: .tabOpen,
            params: AppCommandParams.OpenTab(
                window: nil,
                role: "agent",
                cwd: nil,
                cmd: nil
            )
            )
        let intent = try CLIIntentTranslator.translate(cmd)
        if case let .openTab(win, role, cwd, inner) = intent {
            #expect(win == nil)
            #expect(role == .agent)
            #expect(cwd == nil)
            #expect(inner == nil)
        } else {
            Issue.record("expected .openTab")
        }
    }

    @Test
    func translatesTabOpenClampsExternalAutomationToAgent() throws {
        // The back-channel is the external path; the automation role is
        // human-only (minted only by the in-process menu). A hand-rolled
        // UDS client that sets `role: "automation"` must NOT launder an
        // automation mint through the validated GUI. The translated
        // intent is clamped to `.agent`.
        let cmd = try makeCommand(
            kind: .tabOpen,
            params: AppCommandParams.OpenTab(
                window: Wire.WindowRef(type: "index", value: "2"),
                role: "automation",
                cwd: "/tmp",
                cmd: nil
            )
            )
        let intent = try CLIIntentTranslator.translate(cmd)
        if case let .openTab(_, role, cwd, _) = intent {
            #expect(role == .agent)
            #expect(cwd == "/tmp")
        } else {
            Issue.record("expected .openTab")
        }
    }

    @Test
    func translatesTabCloseWithShutdownMode() throws {
        let cmd = try makeCommand(
            kind: .tabClose,
            params: AppCommandParams.CloseTab(
                tab: Wire.TabRef(type: "current", value: nil),
                mode: "shutdown"
            )
            )
        let intent = try CLIIntentTranslator.translate(cmd)
        if case let .closeTab(ref, mode) = intent {
            #expect(ref == .current)
            #expect(mode == .shutdown)
        } else {
            Issue.record("expected .closeTab")
        }
    }

    @Test
    func translatesTabRenameWithNilRestoresAuto() throws {
        let cmd = try makeCommand(
            kind: .tabRename,
            params: AppCommandParams.RenameTab(
                tab: Wire.TabRef(type: "sessionId", value: "S-A"),
                name: nil
            )
            )
        let intent = try CLIIntentTranslator.translate(cmd)
        if case let .renameTab(ref, name) = intent {
            #expect(ref == .sessionId("S-A"))
            #expect(name == nil)
        } else {
            Issue.record("expected .renameTab")
        }
    }

    @Test
    func translatesTabSelect() throws {
        let cmd = try makeCommand(
            kind: .tabSelect,
            params: AppCommandParams.SelectTab(
                tab: Wire.TabRef(type: "name", value: "auth")
            )
            )
        let intent = try CLIIntentTranslator.translate(cmd)
        #expect(intent == .selectTab(.name("auth")))
    }

    @Test
    func translatesTabInfo() throws {
        let cmd = try makeCommand(
            kind: .tabInfo,
            params: AppCommandParams.TabInfo(
                tab: Wire.TabRef(type: "shortId", value: "abc12")
            )
            )
        let intent = try CLIIntentTranslator.translate(cmd)
        #expect(intent == .tabInfo(.shortId("abc12")))
    }

    // MARK: - Pane verbs

    @Test
    func translatesPaneOpenTerminal() throws {
        let cmd = try makeCommand(
            kind: .paneOpenTerminal,
            params: AppCommandParams.OpenPaneTerminal(
                tab: Wire.TabRef(type: "current", value: nil),
                cwd: "/proj",
                cmd: nil
            )
            )
        let intent = try CLIIntentTranslator.translate(cmd)
        if case let .openPaneTerminal(tab, cwd, inner) = intent {
            #expect(tab == .current)
            #expect(cwd == "/proj")
            #expect(inner == nil)
        } else {
            Issue.record("expected .openPaneTerminal")
        }
    }

    @Test
    func translatesPaneClose() throws {
        let cmd = try makeCommand(
            kind: .paneClose,
            params: AppCommandParams.ClosePane(
                pane: Wire.PaneRef(type: "paneId", value: "P1"),
                mode: "detach"
            )
            )
        let intent = try CLIIntentTranslator.translate(cmd)
        if case let .closePane(pane, mode) = intent {
            #expect(pane == .paneId("P1"))
            #expect(mode == .detach)
        } else {
            Issue.record("expected .closePane")
        }
    }

    @Test
    func translatesPaneAttachSimTarget() throws {
        let cmd = try makeCommand(
            kind: .paneAttach,
            params: AppCommandParams.PaneAttach(target: .sim(udid: "U-iphone17"))
            )
        let intent = try CLIIntentTranslator.translate(cmd)
        #expect(intent == .paneAttach(udid: "U-iphone17"))
    }

    @Test
    func translatesPaneAttachDeviceTarget() throws {
        // A `.device` target on the one published attach command routes
        // to the physical-device intent, not the sim claim. The explicit
        // CLI verb defaults `relinkExisting` false.
        let cmd = try makeCommand(
            kind: .paneAttach,
            params: AppCommandParams.PaneAttach(target: .device(deviceId: "fd00::1"))
            )
        let intent = try CLIIntentTranslator.translate(cmd)
        #expect(intent == .devicePaneAttach(deviceId: "fd00::1", relinkExisting: false))
    }

    @Test
    func translatesPaneAttachDeviceTargetCarriesRelink() throws {
        // The shim's contextual auto-attach sets `relinkExisting`; the
        // translator must carry it into the route intent so the dispatcher
        // moves an already-mirrored device rather than rejecting.
        let cmd = try makeCommand(
            kind: .paneAttach,
            params: AppCommandParams.PaneAttach(
                target: .device(deviceId: "fd00::1"),
                relinkExisting: true
            )
            )
        let intent = try CLIIntentTranslator.translate(cmd)
        #expect(intent == .devicePaneAttach(deviceId: "fd00::1", relinkExisting: true))
    }

    // MARK: - Window verbs

    @Test
    func translatesWindowOpen() throws {
        let cmd = try makeCommand(
            kind: .windowOpen,
            params: AppCommandParams.OpenWindow()
            )
        let intent = try CLIIntentTranslator.translate(cmd)
        #expect(intent == .openWindow)
    }

    @Test
    func translatesWindowClose() throws {
        let cmd = try makeCommand(
            kind: .windowClose,
            params: AppCommandParams.CloseWindow(
                window: Wire.WindowRef(type: "index", value: "2"),
                mode: "shutdown"
            )
            )
        let intent = try CLIIntentTranslator.translate(cmd)
        if case let .closeWindow(ref, mode) = intent {
            #expect(ref == .index(2))
            #expect(mode == .shutdown)
        } else {
            Issue.record("expected .closeWindow")
        }
    }

    @Test
    func translatesWindowFocus() throws {
        let cmd = try makeCommand(
            kind: .windowFocus,
            params: AppCommandParams.FocusWindow(
                window: Wire.WindowRef(type: "current", value: nil)
            )
            )
        let intent = try CLIIntentTranslator.translate(cmd)
        #expect(intent == .focusWindow(.current))
    }

    @Test
    func translatesWindowsListAll() throws {
        let cmd = try makeCommand(
            kind: .windowsList,
            params: AppCommandParams.WindowsList(all: true)
            )
        let intent = try CLIIntentTranslator.translate(cmd)
        #expect(intent == .windowsList(all: true))
    }

    @Test
    func translatesTabSendInput() throws {
        let cmd = try makeCommand(
            kind: .tabSendInput,
            params: AppCommandParams.TabSendInput(
                tab: Wire.TabRef(type: "sessionId", value: "S-A"),
                text: "echo hi\n"
            )
            )
        let intent = try CLIIntentTranslator.translate(cmd)
        if case let .sendInput(ref, text, typeDelayMillis) = intent {
            #expect(ref == .sessionId("S-A"))
            #expect(text == "echo hi\n")
            #expect(typeDelayMillis == nil)
        } else {
            Issue.record("expected .sendInput; got \(intent)")
        }
    }

    @Test
    func translatesTabSendInputWithTypeDelay() throws {
        let cmd = try makeCommand(
            kind: .tabSendInput,
            params: AppCommandParams.TabSendInput(
                tab: Wire.TabRef(type: "sessionId", value: "S-A"),
                text: "echo hi\n",
                typeDelayMillis: 45
            )
            )
        let intent = try CLIIntentTranslator.translate(cmd)
        if case let .sendInput(ref, text, typeDelayMillis) = intent {
            #expect(ref == .sessionId("S-A"))
            #expect(text == "echo hi\n")
            #expect(typeDelayMillis == 45)
        } else {
            Issue.record("expected .sendInput; got \(intent)")
        }
    }

    @Test
    func translatesTabCapture() throws {
        let cmd = try makeCommand(
            kind: .tabCapture,
            params: AppCommandParams.TabCapture(
                tab: Wire.TabRef(type: "shortId", value: "abc12")
            )
            )
        let intent = try CLIIntentTranslator.translate(cmd)
        #expect(intent == .captureTab(.shortId("abc12")))
    }

    // MARK: - Malformed params

    @Test
    func malformedParamsThrows() {
        let bogus = Data(#"{ "tab": 1234 }"#.utf8)
        let cmd = AppCommand(
            commandId: "X",
            kind: .tabClose,
            originatingSessionId: nil,
            params: bogus
        )
        #expect(throws: DecodingError.self) {
            try CLIIntentTranslator.translate(cmd)
        }
    }

    // MARK: - Mode coverage

    @Test(
        arguments: [
        ("detach", PaneCloseMode.detach),
        ("shutdown", PaneCloseMode.shutdown),
        ("unknown-thing", PaneCloseMode.detach)
        ]
        )
    func modeStringFallsBackToDetach(raw: String, expected: PaneCloseMode) throws {
        let cmd = try makeCommand(
            kind: .tabClose,
            params: AppCommandParams.CloseTab(
                tab: Wire.TabRef(type: "current", value: nil),
                mode: raw
            )
            )
        let intent = try CLIIntentTranslator.translate(cmd)
        if case let .closeTab(_, mode) = intent {
            #expect(mode == expected)
        } else {
            Issue.record("expected .closeTab")
        }
    }
}
