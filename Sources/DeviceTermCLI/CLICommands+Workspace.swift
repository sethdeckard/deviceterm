// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Workspace request building and device-attach resolution.
extension CLICommands {
    /// The attach target chosen for `device attach <ref>`.
    public enum DeviceAttachResolution: Equatable, Sendable {
        case target(PaneTarget, id: String, kind: DeviceKind)
        case notFound
        case ambiguous(ids: [String])
    }

    /// Upper bound for paced terminal input.
    public static let maxTypeDelayMillis = 1_000

    /// Resolve a device reference, with a bare Simulator UUID fallback for
    /// externally booted simulators absent from the owned-device roster.
    public static func resolveDeviceAttach(
        ref: String,
        roster: [DeviceRosterEntry]
    ) -> DeviceAttachResolution {
        switch DeviceRosterResolver.resolve(ref, in: roster) {
        case let .entry(entry):
            let target: PaneTarget = entry.kind == .device
                ? .device(deviceId: entry.id)
                : .sim(udid: entry.id)
            return .target(target, id: entry.id, kind: entry.kind)

        case let .ambiguous(hits):
            return .ambiguous(ids: hits.map(\.id))

        case .notFound:
            guard UUID(uuidString: ref) != nil else { return .notFound }
            return .target(.sim(udid: ref), id: ref, kind: .sim)
        }
    }

    /// Resolve a shell working directory before it crosses the wire.
    static func normalizeCwd(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return raw }
        let expanded = (raw as NSString).expandingTildeInPath
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else {
            absolute = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(expanded)
                .path
        }
        return URL(fileURLWithPath: absolute).standardizedFileURL.path
    }

    public static func windowListRequest(all: Bool) throws -> RPCEnvelope {
        try request(method: .windowList, body: AppCommandParams.ListWindows(all: all))
    }

    public static func windowShowRequest(window: String?) throws -> RPCEnvelope {
        try request(method: .windowShow, body: AppCommandParams.ShowWindow(window: window))
    }

    public static func windowOpenRequest() throws -> RPCEnvelope {
        try request(method: .windowOpen, body: AppCommandParams.OpenWindow())
    }

    public static func windowFocusRequest(window: String?) throws -> RPCEnvelope {
        try request(method: .windowFocus, body: AppCommandParams.FocusWindow(window: window))
    }

    public static func windowCloseRequest(
        window: String?,
        mode: WorkspaceCloseMode
    ) throws -> RPCEnvelope {
        try request(
            method: .windowClose,
            body: AppCommandParams.CloseWindow(window: window, mode: mode)
        )
    }

    public static func tabListRequest(window: String?, all: Bool) throws -> RPCEnvelope {
        try request(method: .tabList, body: AppCommandParams.ListTabs(window: window, all: all))
    }

    public static func tabShowRequest(tab: String?) throws -> RPCEnvelope {
        try request(method: .tabShow, body: AppCommandParams.ShowTab(tab: tab))
    }

    public static func tabOpenRequest(
        window: String?,
        cwd: String? = nil,
        command: String? = nil
    ) throws -> RPCEnvelope {
        try request(
            method: .tabOpen,
            body: AppCommandParams.OpenTab(
                window: window,
                cwd: normalizeCwd(cwd),
                command: command.map { [$0] }
            )
        )
    }

    public static func tabFocusRequest(tab: String?) throws -> RPCEnvelope {
        try request(method: .tabFocus, body: AppCommandParams.FocusTab(tab: tab))
    }

    public static func tabCloseRequest(
        tab: String?,
        mode: WorkspaceCloseMode
    ) throws -> RPCEnvelope {
        try request(method: .tabClose, body: AppCommandParams.CloseTab(tab: tab, mode: mode))
    }

    public static func tabRenameRequest(tab: String?, name: String?) throws -> RPCEnvelope {
        try request(method: .tabRename, body: AppCommandParams.RenameTab(tab: tab, name: name))
    }

    public static func tabMoveRequest(
        tab: String?,
        window: String,
        index: Int?
    ) throws -> RPCEnvelope {
        try request(
            method: .tabMove,
            body: AppCommandParams.MoveTab(tab: tab, window: window, index: index)
        )
    }

    public static func tabProtectionRequest(tab: String?, protected: Bool) throws -> RPCEnvelope {
        try request(
            method: protected ? .tabProtect : .tabUnprotect,
            body: AppCommandParams.SetTabProtection(tab: tab)
        )
    }

    public static func paneListRequest(tab: String?) throws -> RPCEnvelope {
        try request(method: .paneList, body: AppCommandParams.ListPanes(tab: tab))
    }

    public static func paneShowRequest(pane: String?) throws -> RPCEnvelope {
        try request(method: .paneShow, body: AppCommandParams.ShowPane(pane: pane))
    }

    public static func paneSplitRequest(
        pane: String?,
        direction: WorkspaceSplitDirection
    ) throws -> RPCEnvelope {
        try request(
            method: .paneSplit,
            body: AppCommandParams.SplitPane(pane: pane, direction: direction)
        )
    }

    public static func paneFocusRequest(pane: String?) throws -> RPCEnvelope {
        try request(method: .paneFocus, body: AppCommandParams.FocusPane(pane: pane))
    }

    public static func paneCloseRequest(
        pane: String?,
        mode: WorkspaceCloseMode?
    ) throws -> RPCEnvelope {
        try request(method: .paneClose, body: AppCommandParams.ClosePane(pane: pane, mode: mode))
    }

    public static func paneRenameRequest(pane: String?, name: String?) throws -> RPCEnvelope {
        try request(method: .paneRename, body: AppCommandParams.RenamePane(pane: pane, name: name))
    }

    public static func paneSendInputRequest(
        pane: String,
        text: String,
        typeDelayMs: Int?
    ) throws -> RPCEnvelope {
        try request(
            method: .paneSendInput,
            body: AppCommandParams.SendPaneInput(
                pane: pane,
                text: text,
                typeDelayMs: typeDelayMs
            )
        )
    }

    public static func paneCaptureTextRequest(pane: String) throws -> RPCEnvelope {
        try request(
            method: .paneCaptureText,
            body: AppCommandParams.CapturePaneText(pane: pane)
        )
    }

    /// Internal attach publication shared by the shim and device verb.
    public static func deviceAttachRequest(target: PaneTarget) throws -> RPCEnvelope {
        try request(
            method: .paneAttach,
            body: AppCommandParams.PaneAttach(target: target)
        )
    }

    public static func devicesListRequest() -> RPCEnvelope {
        RPCEnvelope(
            id: 1,
            type: .request,
            method: RPCMethod.devicesList.rawValue,
            body: .empty
        )
    }
}
