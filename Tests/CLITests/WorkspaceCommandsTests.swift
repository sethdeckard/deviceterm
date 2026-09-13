// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
@testable import DeviceTermCLI
import Foundation
import Testing

/// Parser and wire-builder coverage for the singular workspace command tree.
struct WorkspaceCommandsTests {
    private static let attachRoster = [
        DeviceRosterEntry(
            id: "5E6F7A8B-PHONE-0000-0000-000000000000",
            kind: .sim,
            name: "iPhone 17 Pro",
            state: "Booted"
        ),
        DeviceRosterEntry(
            id: "fd00:1234::a1b2",
            kind: .device,
            name: "field-unit",
            state: "connected"
        )
    ]

    private static func params<Value: Decodable>(
        _ envelope: RPCEnvelope,
        as type: Value.Type = Value.self
    ) throws -> Value {
        guard case let .params(data) = envelope.body else {
            Issue.record("expected params body")
            throw CocoaError(.coderReadCorrupt)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func expectUsage(_ command: CLICommand) {
        guard case .usage = command else {
            Issue.record("expected .usage; got \(command)")
            return
        }
    }

    // MARK: - Singular command tree

    @Test
    func pluralWorkspaceRootsAreRetired() {
        Self.expectUsage(CLICommands.parse(["deviceterm", "windows", "list"]))
        Self.expectUsage(CLICommands.parse(["deviceterm", "tabs", "list"]))
        Self.expectUsage(CLICommands.parse(["deviceterm", "panes", "list"]))
    }

    @Test
    func windowCommandsParseRawReferences() {
        #expect(CLICommands.parse(["deviceterm", "window", "list"]) == .windowList(all: false))
        #expect(CLICommands.parse(["deviceterm", "window", "list", "--all"]) == .windowList(all: true))
        #expect(CLICommands.parse(["deviceterm", "window", "show", "2"]) == .windowShow(window: "2"))
        #expect(CLICommands.parse(["deviceterm", "window", "open"]) == .windowOpen)
        #expect(CLICommands.parse(["deviceterm", "window", "focus", "main"]) == .windowFocus(window: "main"))
        #expect(
            CLICommands.parse(["deviceterm", "window", "close", "abc123", "--mode", "shutdown"])
                == .windowClose(window: "abc123", mode: .shutdown)
        )
    }

    @Test
    func windowCloseDefaultsToCurrentAndDetach() {
        #expect(
            CLICommands.parse(["deviceterm", "window", "close"])
                == .windowClose(window: nil, mode: .detach)
        )
    }

    @Test
    func windowCloseRejectsUnknownMode() {
        Self.expectUsage(
            CLICommands.parse(["deviceterm", "window", "close", "--mode", "erase"])
        )
    }

    @Test
    func tabReadCommandsParseRawReferences() {
        #expect(CLICommands.parse(["deviceterm", "tab", "list"]) == .tabList(window: nil, all: false))
        #expect(
            CLICommands.parse(["deviceterm", "tab", "list", "--window", "2"])
                == .tabList(window: "2", all: false)
        )
        #expect(
            CLICommands.parse(["deviceterm", "tab", "list", "--all"])
                == .tabList(window: nil, all: true)
        )
        #expect(CLICommands.parse(["deviceterm", "tab", "show", "auth"]) == .tabShow(tab: "auth"))
    }

    @Test
    func tabListRejectsWindowWithAll() {
        Self.expectUsage(
            CLICommands.parse(["deviceterm", "tab", "list", "--window", "2", "--all"])
        )
    }

    @Test
    func tabOpenParsesWindowCwdAndCommand() {
        #expect(
            CLICommands.parse([
                "deviceterm", "tab", "open",
                "--window", "main", "--cwd", "/proj", "--command", "claude --print"
            ]) == .tabOpen(window: "main", cwd: "/proj", command: "claude --print")
        )
        #expect(
            CLICommands.parse(["deviceterm", "tab", "open"])
                == .tabOpen(window: nil, cwd: nil, command: nil)
        )
    }

    @Test
    func tabMutationsParse() {
        #expect(
            CLICommands.parse(["deviceterm", "tab", "close", "auth", "--mode", "shutdown"])
                == .tabClose(tab: "auth", mode: .shutdown)
        )
        #expect(CLICommands.parse(["deviceterm", "tab", "focus", "auth"]) == .tabFocus(tab: "auth"))
        #expect(
            CLICommands.parse(["deviceterm", "tab", "move", "auth", "--window", "2", "--index", "1"])
                == .tabMove(tab: "auth", window: "2", index: 1)
        )
        #expect(CLICommands.parse(["deviceterm", "tab", "protect", "auth"]) == .tabProtect(tab: "auth"))
        #expect(CLICommands.parse(["deviceterm", "tab", "unprotect"]) == .tabUnprotect(tab: nil))
    }

    @Test
    func tabMoveRequiresWindowAndNonnegativeIndex() {
        Self.expectUsage(CLICommands.parse(["deviceterm", "tab", "move", "auth"]))
        Self.expectUsage(
            CLICommands.parse(["deviceterm", "tab", "move", "auth", "--window", "2", "--index", "-1"])
        )
    }

    @Test
    func tabRenameSupportsCurrentAndExplicitTab() {
        #expect(
            CLICommands.parse(["deviceterm", "tab", "rename", "Build Workspace"])
                == .tabRename(tab: nil, name: "Build Workspace")
        )
        #expect(
            CLICommands.parse(["deviceterm", "tab", "rename", "auth", "Feature Work"])
                == .tabRename(tab: "auth", name: "Feature Work")
        )
        Self.expectUsage(
            CLICommands.parse(["deviceterm", "tab", "rename", "auth", "Feature", "Work"])
        )
        Self.expectUsage(CLICommands.parse(["deviceterm", "tab", "rename"]))
    }

    @Test(arguments: ["--help", "-h"])
    func tabRenameHelpFlagRequestsHelp(trigger: String) {
        #expect(
            CLICommands.parse(["deviceterm", "tab", "rename", trigger])
                == .help(topic: "tab rename")
        )
        #expect(
            CLICommands.parse(["deviceterm", "tab", "rename", "--", trigger])
                == .tabRename(tab: nil, name: trigger)
        )
    }

    @Test
    func paneReadAndLayoutCommandsParseRawReferences() {
        #expect(CLICommands.parse(["deviceterm", "pane", "list"]) == .paneList(tab: nil))
        #expect(
            CLICommands.parse(["deviceterm", "pane", "list", "--tab", "auth"])
                == .paneList(tab: "auth")
        )
        #expect(CLICommands.parse(["deviceterm", "pane", "show", "term"]) == .paneShow(pane: "term"))
        #expect(
            CLICommands.parse(["deviceterm", "pane", "split", "term", "--direction", "right"])
                == .paneSplit(pane: "term", direction: .right)
        )
        #expect(CLICommands.parse(["deviceterm", "pane", "focus", "term"]) == .paneFocus(pane: "term"))
    }

    @Test
    func paneSplitRequiresKnownDirection() {
        Self.expectUsage(CLICommands.parse(["deviceterm", "pane", "split", "term"]))
        Self.expectUsage(
            CLICommands.parse(["deviceterm", "pane", "split", "term", "--direction", "diagonal"])
        )
    }

    @Test
    func paneCloseAndRenameParse() {
        #expect(
            CLICommands.parse(["deviceterm", "pane", "close", "sim", "--mode", "shutdown"])
                == .paneClose(pane: "sim", mode: .shutdown)
        )
        #expect(
            CLICommands.parse(["deviceterm", "pane", "close", "term"])
                == .paneClose(pane: "term", mode: nil)
        )
        #expect(
            CLICommands.parse(["deviceterm", "pane", "rename", "term", "Logs Tail"])
                == .paneRename(pane: "term", name: "Logs Tail")
        )
        Self.expectUsage(
            CLICommands.parse(["deviceterm", "pane", "rename", "term", "Logs", "Tail"])
        )
        Self.expectUsage(CLICommands.parse(["deviceterm", "pane", "rename"]))
    }

    @Test
    func paneTerminalCommandsRequireAnExplicitPane() {
        #expect(
            CLICommands.parse(["deviceterm", "pane", "send-input", "term", "hello", "world"])
                == .paneSendInput(pane: "term", text: "hello world", typeDelay: nil)
        )
        #expect(
            CLICommands.parse([
                "deviceterm", "pane", "send-input", "term", "--type-delay", "7", #"one\ntwo"#
            ]) == .paneSendInput(pane: "term", text: "one\ntwo", typeDelay: 7)
        )
        #expect(
            CLICommands.parse(["deviceterm", "pane", "capture-text", "term"])
                == .paneCaptureText(pane: "term", ansi: false)
        )
        Self.expectUsage(CLICommands.parse(["deviceterm", "pane", "send-input", "term"]))
        Self.expectUsage(CLICommands.parse(["deviceterm", "pane", "capture-text"]))
    }

    @Test
    func paneCaptureTextAcceptsAnsiEitherSideOfThePane() {
        #expect(
            CLICommands.parse(["deviceterm", "pane", "capture-text", "term", "--ansi"])
                == .paneCaptureText(pane: "term", ansi: true)
        )
        #expect(
            CLICommands.parse(["deviceterm", "pane", "capture-text", "--ansi", "term"])
                == .paneCaptureText(pane: "term", ansi: true)
        )
    }

    @Test
    func paneCaptureTextRejectsMalformedAnsiUsage() {
        Self.expectUsage(CLICommands.parse(["deviceterm", "pane", "capture-text", "--ansi"]))
        // `--ansi` is a flag, so neither a negation nor a value is offered.
        Self.expectUsage(
            CLICommands.parse(["deviceterm", "pane", "capture-text", "term", "--no-ansi"])
        )
        Self.expectUsage(
            CLICommands.parse(["deviceterm", "pane", "capture-text", "term", "--ansi=true"])
        )
    }

    @Test
    func paneSendInputValidatesAndCapsTypeDelay() {
        Self.expectUsage(
            CLICommands.parse([
                "deviceterm", "pane", "send-input", "term", "--type-delay", "-1", "x"
            ])
        )
        #expect(
            CLICommands.parse([
                "deviceterm", "pane", "send-input", "term", "--type-delay", "9000", "x"
            ]) == .paneSendInput(
                pane: "term",
                text: "x",
                typeDelay: CLICommands.maxTypeDelayMillis
            )
        )
    }

    @Test
    func removedPaneOpenMoveAndAttachFormsAreUsage() {
        Self.expectUsage(CLICommands.parse(["deviceterm", "pane", "open", "terminal"]))
        Self.expectUsage(CLICommands.parse(["deviceterm", "pane", "move", "term"]))
        Self.expectUsage(CLICommands.parse(["deviceterm", "pane", "attach", "phone"]))
    }

    // MARK: - Exact wire requests

    @Test
    func windowRequestsEncodeRawRefsAndModes() throws {
        let list = try CLICommands.windowListRequest(all: true)
        #expect(list.method == RPCMethod.windowList.rawValue)
        #expect(try Self.params(list, as: AppCommandParams.ListWindows.self) == .init(all: true))

        let close = try CLICommands.windowCloseRequest(window: "2", mode: .shutdown)
        #expect(close.method == RPCMethod.windowClose.rawValue)
        #expect(
            try Self.params(close, as: AppCommandParams.CloseWindow.self)
                == .init(window: "2", mode: .shutdown)
        )
    }

    @Test
    func tabRequestsEncodeRawRefsAndOptions() throws {
        let open = try CLICommands.tabOpenRequest(window: "main", cwd: "/tmp", command: "pwd")
        #expect(open.method == RPCMethod.tabOpen.rawValue)
        #expect(
            try Self.params(open, as: AppCommandParams.OpenTab.self)
                == .init(window: "main", cwd: "/tmp", command: ["pwd"])
        )

        let move = try CLICommands.tabMoveRequest(tab: "auth", window: "2", index: 1)
        #expect(move.method == RPCMethod.tabMove.rawValue)
        #expect(
            try Self.params(move, as: AppCommandParams.MoveTab.self)
                == .init(tab: "auth", window: "2", index: 1)
        )

        let protect = try CLICommands.tabProtectionRequest(tab: "auth", protected: true)
        #expect(protect.method == RPCMethod.tabProtect.rawValue)
        #expect(
            try Self.params(protect, as: AppCommandParams.SetTabProtection.self)
                == .init(tab: "auth")
        )
    }

    @Test
    func paneRequestsEncodeExplicitTerminalTarget() throws {
        let split = try CLICommands.paneSplitRequest(pane: "term", direction: .left)
        #expect(split.method == RPCMethod.paneSplit.rawValue)
        #expect(
            try Self.params(split, as: AppCommandParams.SplitPane.self)
                == .init(pane: "term", direction: .left)
        )

        let send = try CLICommands.paneSendInputRequest(pane: "term", text: "ls\n", typeDelayMs: 4)
        #expect(send.method == RPCMethod.paneSendInput.rawValue)
        #expect(
            try Self.params(send, as: AppCommandParams.SendPaneInput.self)
                == .init(pane: "term", text: "ls\n", typeDelayMs: 4)
        )

        let capture = try CLICommands.paneCaptureTextRequest(pane: "term")
        #expect(capture.method == RPCMethod.paneCaptureText.rawValue)
        #expect(
            try Self.params(capture, as: AppCommandParams.CapturePaneText.self)
                == .init(pane: "term")
        )

        let styled = try CLICommands.paneCaptureTextRequest(pane: "term", ansi: true)
        #expect(styled.method == RPCMethod.paneCaptureText.rawValue)
        #expect(
            try Self.params(styled, as: AppCommandParams.CapturePaneText.self)
                == .init(pane: "term", ansi: true)
        )
    }

    // MARK: - Device attach remains device-scoped

    @Test
    func deviceAttachParsesAndRetainsDeviceList() {
        #expect(
            CLICommands.parse(["deviceterm", "device", "attach", "phone"])
                == .deviceAttach(ref: "phone")
        )
        #expect(CLICommands.parse(["deviceterm", "devices", "list"]) == .devicesList)
    }

    @Test
    func resolveDeviceAttachUsesRosterKinds() {
        #expect(
            CLICommands.resolveDeviceAttach(ref: "iPhone 17 Pro", roster: Self.attachRoster)
                == .target(
                    .sim(udid: "5E6F7A8B-PHONE-0000-0000-000000000000"),
                    id: "5E6F7A8B-PHONE-0000-0000-000000000000",
                    kind: .sim
                )
        )
        #expect(
            CLICommands.resolveDeviceAttach(ref: "field-unit", roster: Self.attachRoster)
                == .target(.device(deviceId: "fd00:1234::a1b2"), id: "fd00:1234::a1b2", kind: .device)
        )
    }

    @Test
    func resolveDeviceAttachFallsBackOnlyForUUID() {
        let udid = "550E8400-E29B-41D4-A716-446655440000"
        #expect(
            CLICommands.resolveDeviceAttach(ref: udid, roster: Self.attachRoster)
                == .target(.sim(udid: udid), id: udid, kind: .sim)
        )
        #expect(CLICommands.resolveDeviceAttach(ref: "missing", roster: Self.attachRoster) == .notFound)
    }

    @Test
    func resolveDeviceAttachSurfacesAmbiguity() {
        let roster = [
            DeviceRosterEntry(id: "one", kind: .sim, name: "twin", state: "Booted"),
            DeviceRosterEntry(id: "two", kind: .device, name: "twin", state: "connected")
        ]
        #expect(
            CLICommands.resolveDeviceAttach(ref: "twin", roster: roster)
                == .ambiguous(ids: ["one", "two"])
        )
    }

    @Test
    func deviceAttachRequestUsesInternalPaneAttachMethod() throws {
        let envelope = try CLICommands.deviceAttachRequest(target: .device(deviceId: "phone"))
        #expect(envelope.method == RPCMethod.paneAttach.rawValue)
        #expect(
            try Self.params(envelope, as: AppCommandParams.PaneAttach.self)
                == .init(target: .device(deviceId: "phone"))
        )
    }

    // MARK: - Shared normalization

    @Test
    func normalizeCwdResolvesAndStandardizesPaths() {
        let cwd = FileManager.default.currentDirectoryPath
        #expect(CLICommands.normalizeCwd(".") == cwd)
        #expect(CLICommands.normalizeCwd("subdir") == "\(cwd)/subdir")
        #expect(CLICommands.normalizeCwd("/tmp/foo/..") == "/tmp")
        #expect(CLICommands.normalizeCwd(nil) == nil)
        #expect(CLICommands.normalizeCwd("")?.isEmpty == true)
    }

    @Test(arguments: [
        (#"line\nnext"#, "line\nnext"),
        (#"tab\tvalue"#, "tab\tvalue"),
        (#"slash\\value"#, "slash\\value")
    ])
    func decodeEscapesHonorsCStyleSet(raw: String, expected: String) {
        #expect(CLICommands.decodeEscapes(raw) == expected)
    }

    @Test
    func decodeEscapesPreservesUnknownAndDanglingEscapes() {
        #expect(CLICommands.decodeEscapes(#"\z"#) == #"\z"#)
        #expect(CLICommands.decodeEscapes("end\\") == "end\\")
    }
}
