// SPDX-License-Identifier: GPL-3.0-or-later
//
// CLIIntentTranslator: pure mapping from the daemon's `AppCommand`
// wire frame to the GUI's `RouteIntent`.
//
// One source-specific translator per input boundary (CLI, deep link,
// future AppleScript). Each is a thin shape-converter: decode the
// wire's per-kind params struct, build the matching `RouteIntent`,
// surface decode errors as typed `IntentError`s. No workspace
// access, no dispatch logic. The dispatcher takes it from here.
//
// Wire shape: `AppCommand.kind` is the discriminator,
// `AppCommand.params` is the JSON blob of the matching
// `AppCommandParams.<Kind>` struct. The translator decodes per kind
// and produces a strongly-typed `RouteIntent`.

import DaemonProtocol
import Foundation

enum CLIIntentTranslator {
    /// Convert an incoming AppCommand to a RouteIntent the
    /// IntentDispatcher can consume. Throws `IntentError.internalError`
    /// on a malformed params blob, since the daemon should never publish
    /// one, so this lands as an internal-bug surface rather than a
    /// caller-visible error.
    static func translate(_ command: AppCommand) throws -> RouteIntent {
        let decoder = JSONDecoder()
        switch command.kind {
        case .tabOpen:
            let params = try decoder.decode(
                AppCommandParams.OpenTab.self,
                from: command.params
            )
            // The back-channel is the EXTERNAL path: a CLI/UDS caller.
            // The automation role is human-only: it is minted solely by
            // the in-process "Open Automation Tab" menu, which builds its
            // RouteIntent directly and never routes through here. So an
            // external `tab.open` always yields an `.agent` tab, regardless
            // of any `params.role` a hand-rolled UDS client sets, otherwise
            // it could launder an automation mint through the validated
            // GUI (the daemon's `session.create` gate refuses a UDS mint,
            // but the GUI, as a validated peer, would mint on its behalf).
            // The real CLI only ever sends "agent" here.
            return .openTab(
                inWindow: params.window.map(decodeWindowRef),
                role: .agent,
                cwd: params.cwd,
                cmd: params.cmd
            )

        case .tabClose:
            let params = try decoder.decode(
                AppCommandParams.CloseTab.self,
                from: command.params
            )
            return .closeTab(decodeTabRef(params.tab), mode: decodeMode(params.mode))

        case .tabRename:
            let params = try decoder.decode(
                AppCommandParams.RenameTab.self,
                from: command.params
            )
            return .renameTab(decodeTabRef(params.tab), name: params.name)

        case .tabSelect:
            let params = try decoder.decode(
                AppCommandParams.SelectTab.self,
                from: command.params
            )
            return .selectTab(decodeTabRef(params.tab))

        case .tabInfo:
            let params = try decoder.decode(
                AppCommandParams.TabInfo.self,
                from: command.params
            )
            return .tabInfo(decodeTabRef(params.tab))

        case .tabMove:
            let params = try decoder.decode(
                AppCommandParams.MoveTab.self,
                from: command.params
            )
            return .moveTab(
                decodeTabRef(params.tab),
                toIndex: params.toIndex,
                toWindow: params.toWindow.map(decodeWindowRef)
            )

        case .paneOpenTerminal:
            let params = try decoder.decode(
                AppCommandParams.OpenPaneTerminal.self,
                from: command.params
            )
            return .openPaneTerminal(
                inTab: params.tab.map(decodeTabRef),
                cwd: params.cwd,
                cmd: params.cmd
            )

        case .paneClose:
            let params = try decoder.decode(
                AppCommandParams.ClosePane.self,
                from: command.params
            )
            return .closePane(
                decodePaneRef(params.pane),
                mode: decodeMode(params.mode)
            )

        case .paneRename:
            let params = try decoder.decode(
                AppCommandParams.RenamePane.self,
                from: command.params
            )
            return .renamePane(decodePaneRef(params.pane), name: params.name)

        case .paneInfo:
            let params = try decoder.decode(
                AppCommandParams.PaneInfo.self,
                from: command.params
            )
            return .paneInfo(decodePaneRef(params.pane))

        case .paneMove:
            let params = try decoder.decode(
                AppCommandParams.MovePane.self,
                from: command.params
            )
            return .movePane(
                decodePaneRef(params.pane),
                toTab: decodeTabRef(params.toTab)
            )

        case .paneAttach:
            let params = try decoder.decode(
                AppCommandParams.PaneAttach.self,
                from: command.params
            )
            // One published command, two routes: a `.sim` ref claims a
            // simulator (the existing sim attach path); a `.device` ref
            // mounts a physically-connected device.
            switch params.target {
            case let .sim(udid):
                return .paneAttach(udid: udid)

            case let .device(deviceId):
                return .devicePaneAttach(
                    deviceId: deviceId,
                    relinkExisting: params.relinkExisting
                )
            }

        case .windowOpen:
            _ = try decoder.decode(
                AppCommandParams.OpenWindow.self,
                from: command.params
            )
            return .openWindow

        case .windowClose:
            let params = try decoder.decode(
                AppCommandParams.CloseWindow.self,
                from: command.params
            )
            return .closeWindow(
                decodeWindowRef(params.window),
                mode: decodeMode(params.mode)
            )

        case .windowFocus:
            let params = try decoder.decode(
                AppCommandParams.FocusWindow.self,
                from: command.params
            )
            return .focusWindow(decodeWindowRef(params.window))

        case .windowsList:
            let params = try decoder.decode(
                AppCommandParams.WindowsList.self,
                from: command.params
            )
            return .windowsList(all: params.all)

        case .tabSendInput:
            let params = try decoder.decode(
                AppCommandParams.TabSendInput.self,
                from: command.params
            )
            return .sendInput(
                decodeTabRef(params.tab),
                text: params.text,
                typeDelayMillis: params.typeDelayMillis
            )

        case .tabCapture:
            let params = try decoder.decode(
                AppCommandParams.TabCapture.self,
                from: command.params
            )
            return .captureTab(decodeTabRef(params.tab))

        case .tabSetProtected:
            let params = try decoder.decode(
                AppCommandParams.SetTabProtected.self,
                from: command.params
            )
            return .setTabProtected(
                decodeTabRef(params.tab),
                isProtected: params.isProtected
            )
        }
    }

    // MARK: - Ref decoders

    private static func decodeTabRef(_ wire: Wire.TabRef) -> TabRef {
        switch wire.type {
        case "current":
            return .current

        case "sessionId":
            return .sessionId(wire.value ?? "")

        case "shortId":
            return .shortId(wire.value ?? "")

        case "name":
            return .name(wire.value ?? "")

        default:
            return .current
        }
    }

    private static func decodePaneRef(_ wire: Wire.PaneRef) -> PaneRef {
        switch wire.type {
        case "current":
            return .current

        case "paneId":
            return .paneId(wire.value ?? "")

        case "udid":
            return .udid(wire.value ?? "")

        case "shortId":
            return .shortId(wire.value ?? "")

        default:
            return .current
        }
    }

    private static func decodeWindowRef(_ wire: Wire.WindowRef) -> WindowRef {
        switch wire.type {
        case "current":
            return .current

        case "index":
            return .index(Int(wire.value ?? "1") ?? 1)

        case "keyed":
            return .keyed(wire.value ?? "")

        default:
            return .current
        }
    }

    private static func decodeMode(_ raw: String) -> PaneCloseMode {
        switch raw {
        case "shutdown":
            return .shutdown

        case "detach":
            return .detach

        default:
            return .detach
        }
    }
}
