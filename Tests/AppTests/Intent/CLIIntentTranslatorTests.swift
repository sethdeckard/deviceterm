// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import Testing

/// Pins every public workspace command to its raw-ref GUI intent.
struct CLIIntentTranslatorTests {
    private func command<Params: Encodable>(
        _ kind: AppCommandKind,
        _ params: Params
    ) throws -> AppCommand {
        AppCommand(
            commandId: "cmd-\(kind.rawValue)",
            kind: kind,
            originatingSessionId: "SESSION",
            params: try JSONEncoder().encode(params)
        )
    }

    @Test
    func translatesWindowCommands() throws {
        #expect(
            try CLIIntentTranslator.translate(command(.windowList, AppCommandParams.ListWindows(all: true)))
                == .workspaceWindowList(all: true)
        )
        #expect(
            try CLIIntentTranslator.translate(command(.windowShow, AppCommandParams.ShowWindow(window: "2")))
                == .workspaceWindowShow("2")
        )
        #expect(
            try CLIIntentTranslator.translate(command(.windowOpen, AppCommandParams.OpenWindow()))
                == .workspaceWindowOpen
        )
        #expect(
            try CLIIntentTranslator.translate(command(.windowFocus, AppCommandParams.FocusWindow(window: nil)))
                == .workspaceWindowFocus(nil)
        )
        #expect(
            try CLIIntentTranslator.translate(
                command(.windowClose, AppCommandParams.CloseWindow(window: "main", mode: .shutdown))
            ) == .workspaceWindowClose("main", mode: .shutdown)
        )
    }

    @Test
    func translatesTabReadsAndOpen() throws {
        #expect(
            try CLIIntentTranslator.translate(
                command(.tabList, AppCommandParams.ListTabs(window: "2", all: false))
            ) == .workspaceTabList(window: "2", all: false)
        )
        #expect(
            try CLIIntentTranslator.translate(command(.tabShow, AppCommandParams.ShowTab(tab: "auth")))
                == .workspaceTabShow("auth")
        )
        #expect(
            try CLIIntentTranslator.translate(
                command(
                    .tabOpen,
                    AppCommandParams.OpenTab(window: "main", cwd: "/project", command: ["pwd"])
                )
            ) == .workspaceTabOpen(window: "main", cwd: "/project", command: ["pwd"])
        )
    }

    @Test
    func translatesTabMutations() throws {
        #expect(
            try CLIIntentTranslator.translate(
                command(.tabClose, AppCommandParams.CloseTab(tab: "auth", mode: .detach))
            ) == .workspaceTabClose("auth", mode: .detach)
        )
        #expect(
            try CLIIntentTranslator.translate(
                command(.tabRename, AppCommandParams.RenameTab(tab: nil, name: "Build"))
            ) == .workspaceTabRename(nil, name: "Build")
        )
        #expect(
            try CLIIntentTranslator.translate(command(.tabFocus, AppCommandParams.FocusTab(tab: "auth")))
                == .workspaceTabFocus("auth")
        )
        #expect(
            try CLIIntentTranslator.translate(
                command(.tabMove, AppCommandParams.MoveTab(tab: "auth", window: "2", index: 1))
            ) == .workspaceTabMove("auth", window: "2", index: 1)
        )
        #expect(
            try CLIIntentTranslator.translate(
                command(.tabProtect, AppCommandParams.SetTabProtection(tab: "auth"))
            ) == .workspaceTabProtect("auth", protected: true)
        )
        #expect(
            try CLIIntentTranslator.translate(
                command(.tabUnprotect, AppCommandParams.SetTabProtection(tab: "auth"))
            ) == .workspaceTabProtect("auth", protected: false)
        )
    }

    @Test
    func translatesPaneReadsAndLayoutMutations() throws {
        #expect(
            try CLIIntentTranslator.translate(command(.paneList, AppCommandParams.ListPanes(tab: "auth")))
                == .workspacePaneList(tab: "auth")
        )
        #expect(
            try CLIIntentTranslator.translate(command(.paneShow, AppCommandParams.ShowPane(pane: "shell")))
                == .workspacePaneShow("shell")
        )
        #expect(
            try CLIIntentTranslator.translate(
                command(.paneSplit, AppCommandParams.SplitPane(pane: nil, direction: .right))
            ) == .workspacePaneSplit(nil, direction: .right)
        )
        #expect(
            try CLIIntentTranslator.translate(command(.paneFocus, AppCommandParams.FocusPane(pane: "shell")))
                == .workspacePaneFocus("shell")
        )
        #expect(
            try CLIIntentTranslator.translate(
                command(.paneClose, AppCommandParams.ClosePane(pane: "sim", mode: .shutdown))
            ) == .workspacePaneClose("sim", mode: .shutdown)
        )
        #expect(
            try CLIIntentTranslator.translate(
                command(.paneRename, AppCommandParams.RenamePane(pane: "sim", name: nil))
            ) == .workspacePaneRename("sim", name: nil)
        )
    }

    @Test
    func translatesExplicitTerminalCommands() throws {
        #expect(
            try CLIIntentTranslator.translate(
                command(
                    .paneSendInput,
                    AppCommandParams.SendPaneInput(pane: "shell", text: "ls\n", typeDelayMs: 8)
                )
            ) == .workspacePaneSendInput("shell", text: "ls\n", typeDelayMs: 8)
        )
        #expect(
            try CLIIntentTranslator.translate(
                command(.paneCaptureText, AppCommandParams.CapturePaneText(pane: "shell"))
            ) == .workspacePaneCaptureText("shell", ansi: false)
        )
    }

    @Test
    func translatesInternalAttachTargets() throws {
        #expect(
            try CLIIntentTranslator.translate(
                command(.paneAttach, AppCommandParams.PaneAttach(target: .sim(udid: "SIM")))
            ) == .paneAttach(udid: "SIM")
        )
        #expect(
            try CLIIntentTranslator.translate(
                command(
                    .paneAttach,
                    AppCommandParams.PaneAttach(
                        target: .device(deviceId: "PHONE"),
                        relinkExisting: true
                    )
                )
            ) == .devicePaneAttach(deviceId: "PHONE", relinkExisting: true)
        )
    }

    @Test
    func malformedParamsThrow() {
        let malformed = AppCommand(
            commandId: "bad",
            kind: .paneSplit,
            originatingSessionId: nil,
            params: Data("{}".utf8)
        )
        #expect(throws: DecodingError.self) {
            _ = try CLIIntentTranslator.translate(malformed)
        }
    }
}
