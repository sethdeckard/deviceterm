// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Pure mapping from one daemon-published command to a typed GUI intent.
enum CLIIntentTranslator {
    static func translate(_ command: AppCommand) throws -> RouteIntent {
        let decoder = JSONDecoder()
        switch command.kind {
        case .windowList:
            let params = try decoder.decode(AppCommandParams.ListWindows.self, from: command.params)
            return .workspaceWindowList(all: params.all)

        case .windowShow:
            let params = try decoder.decode(AppCommandParams.ShowWindow.self, from: command.params)
            return .workspaceWindowShow(params.window)

        case .windowOpen:
            _ = try decoder.decode(AppCommandParams.OpenWindow.self, from: command.params)
            return .workspaceWindowOpen

        case .windowFocus:
            let params = try decoder.decode(AppCommandParams.FocusWindow.self, from: command.params)
            return .workspaceWindowFocus(params.window)

        case .windowClose:
            let params = try decoder.decode(AppCommandParams.CloseWindow.self, from: command.params)
            return .workspaceWindowClose(params.window, mode: params.mode)

        case .automationStatus:
            _ = try decoder.decode(AppCommandParams.ListAutomationPrograms.self, from: command.params)
            return .automationProgramStatus

        case .automationRestart:
            let params = try decoder.decode(
                AppCommandParams.RestartAutomationProgram.self,
                from: command.params
            )
            return .automationProgramRestart(name: params.name)

        case .tabList:
            let params = try decoder.decode(AppCommandParams.ListTabs.self, from: command.params)
            return .workspaceTabList(window: params.window, all: params.all)

        case .tabShow:
            let params = try decoder.decode(AppCommandParams.ShowTab.self, from: command.params)
            return .workspaceTabShow(params.tab)

        case .tabOpen:
            let params = try decoder.decode(AppCommandParams.OpenTab.self, from: command.params)
            return .workspaceTabOpen(
                window: params.window,
                cwd: params.cwd,
                command: params.command
            )

        case .tabFocus:
            let params = try decoder.decode(AppCommandParams.FocusTab.self, from: command.params)
            return .workspaceTabFocus(params.tab)

        case .tabClose:
            let params = try decoder.decode(AppCommandParams.CloseTab.self, from: command.params)
            return .workspaceTabClose(params.tab, mode: params.mode)

        case .tabRename:
            let params = try decoder.decode(AppCommandParams.RenameTab.self, from: command.params)
            return .workspaceTabRename(params.tab, name: params.name)

        case .tabMove:
            let params = try decoder.decode(AppCommandParams.MoveTab.self, from: command.params)
            return .workspaceTabMove(params.tab, window: params.window, index: params.index)

        case .tabProtect:
            let params = try decoder.decode(AppCommandParams.SetTabProtection.self, from: command.params)
            return .workspaceTabProtect(params.tab, protected: true)

        case .tabUnprotect:
            let params = try decoder.decode(AppCommandParams.SetTabProtection.self, from: command.params)
            return .workspaceTabProtect(params.tab, protected: false)

        case .paneList:
            let params = try decoder.decode(AppCommandParams.ListPanes.self, from: command.params)
            return .workspacePaneList(tab: params.tab, all: params.all)

        case .paneShow:
            let params = try decoder.decode(AppCommandParams.ShowPane.self, from: command.params)
            return .workspacePaneShow(params.pane)

        case .paneSplit:
            let params = try decoder.decode(AppCommandParams.SplitPane.self, from: command.params)
            return .workspacePaneSplit(params.pane, direction: params.direction)

        case .paneFocus:
            let params = try decoder.decode(AppCommandParams.FocusPane.self, from: command.params)
            return .workspacePaneFocus(params.pane)

        case .paneClose:
            let params = try decoder.decode(AppCommandParams.ClosePane.self, from: command.params)
            return .workspacePaneClose(params.pane, mode: params.mode)

        case .paneRename:
            let params = try decoder.decode(AppCommandParams.RenamePane.self, from: command.params)
            return .workspacePaneRename(params.pane, name: params.name)

        case .paneSendInput:
            let params = try decoder.decode(AppCommandParams.SendPaneInput.self, from: command.params)
            return .workspacePaneSendInput(
                params.pane,
                text: params.text,
                typeDelayMs: params.typeDelayMs
            )

        case .paneCaptureText:
            let params = try decoder.decode(AppCommandParams.CapturePaneText.self, from: command.params)
            return .workspacePaneCaptureText(params.pane, ansi: params.ansi)

        case .paneAttach:
            let params = try decoder.decode(AppCommandParams.PaneAttach.self, from: command.params)
            switch params.target {
            case let .sim(udid):
                return .paneAttach(udid: udid)

            case let .device(deviceId):
                return .devicePaneAttach(
                    deviceId: deviceId,
                    relinkExisting: params.relinkExisting
                )
            }
        }
    }
}
