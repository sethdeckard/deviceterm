// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Workspace request building and device-attach resolution. The command
/// declarations under `Commands/` own the parsing; the `*Request`
/// builders here encode the matching `AppCommandParams` struct for the
/// daemon's `app.commands` back-channel.
///
/// This is a behavior-grouping extension, not a conformance split. The
/// shared `request(method:body:)` helper is `internal` in
/// CLICommands.swift so this file can call it.
extension CLICommands {
    // MARK: - Nested types

    /// The attach target chosen for `device attach <ref>`, plus the
    /// echo identity (`id` + `kind`). See `resolveDeviceAttach`.
    public enum DeviceAttachResolution: Equatable, Sendable {
        case target(PaneTarget, id: String, kind: DeviceKind)
        case notFound
        case ambiguous(ids: [String])
    }

    // MARK: - Constants

    /// Upper bound for `tab send-input --type-delay <ms>`, matching the
    /// GUI's per-character animation clamp. Capping at parse keeps the
    /// wire value bounded so no downstream arithmetic can overflow and
    /// a fat-fingered value can't wedge the pane; 1 s/char is already
    /// the slowest sensible typing speed.
    public static let maxTypeDelayMillis = 1_000

    // MARK: - Device attachment resolution

    /// Resolve `device attach <ref>` against the `devices.list` roster,
    /// with the **external-sim claim fallback**: an unresolved ref that
    /// is a bare UUID is treated as a sim UDID passthrough. The daemon
    /// roster (`devices.list`) lists only *owned* booted sims, so an
    /// externally-booted / shim-bypassing / orphan sim (the exact
    /// claim target the retired `pane attach` subverb served) is absent
    /// from it. Passing the UDID straight through preserves that claim
    /// path; the daemon validates the UDID and surfaces a clear error
    /// if no such sim exists. A non-UUID miss stays a hard not-found
    /// (a typo / unknown name, where the roster error is friendlier).
    /// A physical device can never reach the fallback: it must be
    /// enumerated to have a deviceId at all, so it is always in the
    /// roster when attachable.
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

    // MARK: - Workspace verb request builders
    //
    // One per `AppCommandKind`. Each encodes the matching
    // `AppCommandParams.<Kind>` struct as the request body; the
    // daemon's `AppCommandMethods.publishVerb` decodes it on the
    // back-channel publish path. The role is always "agent", with no
    // CLI verb spawns an automation session.

    /// Resolve `--cwd <path>` to an absolute path before it crosses
    /// the wire. libghostty's `working_directory` validates with an
    /// `open(absolute)` and silently falls back to the default when
    /// the path is relative or `~`-prefixed (quoted `~` survives
    /// argv intact when the shell doesn't expand it). Doing the
    /// resolve here means the GUI sees a canonical absolute path
    /// for every caller: `--cwd .`, `--cwd ~/proj`,
    /// `--cwd /abs/path` all land equivalently. `nil` passes
    /// through unchanged so the default "spawn at GUI cwd"
    /// behavior stays intact.
    static func normalizeCwd(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return raw }
        let expanded = (raw as NSString).expandingTildeInPath
        let absolute: String
        if expanded.hasPrefix("/") {
            absolute = expanded
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            absolute = URL(fileURLWithPath: cwd)
                .appendingPathComponent(expanded)
                .path
        }
        return URL(fileURLWithPath: absolute).standardizedFileURL.path
    }

    public static func tabOpenRequest(
        window: Wire.WindowRef?,
        cwd: String? = nil,
        cmd: String? = nil
    ) throws -> RPCEnvelope {
        // `cmd` rides as a single-element argv on the wire; the
        // GUI joins on spaces (degenerate for length-1) and types
        // the result into the shell via libghostty's
        // `initial_input`. The wire stays `[String]?` so a future
        // programmatic caller can send true argv if it ever needs
        // to bypass the shell.
        try request(
            method: .tabOpen,
            body: AppCommandParams.OpenTab(
                window: window,
                role: "agent",
                cwd: normalizeCwd(cwd),
                cmd: cmd.map { [$0] }
            )
        )
    }

    public static func tabCloseRequest(
        tab: Wire.TabRef,
        mode: String
    ) throws -> RPCEnvelope {
        try request(
            method: .tabClose,
            body: AppCommandParams.CloseTab(
            tab: tab,
            mode: mode
        )
            )
    }

    public static func tabRenameRequest(
        tab: Wire.TabRef,
        name: String?
    ) throws -> RPCEnvelope {
        try request(
            method: .tabRename,
            body: AppCommandParams.RenameTab(
            tab: tab,
            name: name
        )
            )
    }

    public static func tabSelectRequest(
        tab: Wire.TabRef
    ) throws -> RPCEnvelope {
        try request(method: .tabSelect, body: AppCommandParams.SelectTab(tab: tab))
    }

    public static func tabInfoRequest(
        tab: Wire.TabRef
    ) throws -> RPCEnvelope {
        try request(method: .tabInfo, body: AppCommandParams.TabInfo(tab: tab))
    }

    public static func tabMoveRequest(
        tab: Wire.TabRef,
        toIndex: Int?,
        toWindow: Wire.WindowRef?
    ) throws -> RPCEnvelope {
        try request(
            method: .tabMove,
            body: AppCommandParams.MoveTab(
                tab: tab,
                toIndex: toIndex,
                toWindow: toWindow
            )
        )
    }

    public static func paneOpenTerminalRequest(
        tab: Wire.TabRef?,
        cwd: String? = nil,
        cmd: String? = nil
    ) throws -> RPCEnvelope {
        try request(
            method: .paneOpenTerminal,
            body: AppCommandParams.OpenPaneTerminal(
                tab: tab,
                cwd: normalizeCwd(cwd),
                cmd: cmd.map { [$0] }
            )
        )
    }

    public static func paneCloseRequest(
        pane: Wire.PaneRef,
        mode: String
    ) throws -> RPCEnvelope {
        try request(
            method: .paneClose,
            body: AppCommandParams.ClosePane(
            pane: pane,
            mode: mode
        )
            )
    }

    public static func paneRenameRequest(
        pane: Wire.PaneRef,
        name: String?
    ) throws -> RPCEnvelope {
        try request(
            method: .paneRename,
            body: AppCommandParams.RenamePane(
            pane: pane,
            name: name
        )
            )
    }

    public static func paneInfoRequest(
        pane: Wire.PaneRef
    ) throws -> RPCEnvelope {
        try request(method: .paneInfo, body: AppCommandParams.PaneInfo(pane: pane))
    }

    public static func paneMoveRequest(
        pane: Wire.PaneRef,
        toTab: Wire.TabRef
    ) throws -> RPCEnvelope {
        try request(
            method: .paneMove,
            body: AppCommandParams.MovePane(
            pane: pane,
            toTab: toTab
        )
            )
    }

    /// `deviceterm device attach <ref>` → the attach back-channel
    /// `pane.attach` publish, carrying the resolved `PaneTarget`
    /// (`.sim` claims a booted/orphan sim; `.device` mirrors a physical
    /// device). One route serves both kinds.
    public static func deviceAttachRequest(target: PaneTarget) throws -> RPCEnvelope {
        try request(
            method: .paneAttach,
            body: AppCommandParams.PaneAttach(target: target)
        )
    }

    /// `deviceterm devices list` → the session-scoped `devices.list` RPC.
    /// No body: the daemon reads the originating session from the
    /// connection's authenticated context.
    public static func devicesListRequest() -> RPCEnvelope {
        RPCEnvelope(id: 1, type: .request, method: RPCMethod.devicesList.rawValue, body: .empty)
    }

    public static func windowOpenRequest() throws -> RPCEnvelope {
        try request(method: .windowOpen, body: AppCommandParams.OpenWindow())
    }

    public static func windowCloseRequest(
        window: Wire.WindowRef,
        mode: String
    ) throws -> RPCEnvelope {
        try request(
            method: .windowClose,
            body: AppCommandParams.CloseWindow(
            window: window,
            mode: mode
        )
            )
    }

    public static func windowFocusRequest(
        window: Wire.WindowRef
    ) throws -> RPCEnvelope {
        try request(
            method: .windowFocus,
            body: AppCommandParams.FocusWindow(
            window: window
        )
            )
    }

    public static func windowsListRequest(all: Bool) throws -> RPCEnvelope {
        try request(method: .windowsList, body: AppCommandParams.WindowsList(all: all))
    }

    public static func tabSendInputRequest(
        tab: Wire.TabRef,
        text: String,
        typeDelayMillis: Int? = nil
    ) throws -> RPCEnvelope {
        try request(
            method: .tabSendInput,
            body: AppCommandParams.TabSendInput(
            tab: tab,
            text: text,
            typeDelayMillis: typeDelayMillis
        )
            )
    }

    public static func tabCaptureRequest(
        tab: Wire.TabRef
    ) throws -> RPCEnvelope {
        try request(method: .tabCapture, body: AppCommandParams.TabCapture(tab: tab))
    }

    public static func tabSetProtectedRequest(
        tab: Wire.TabRef,
        isProtected: Bool
    ) throws -> RPCEnvelope {
        try request(
            method: .tabSetProtected,
            body: AppCommandParams.SetTabProtected(
            tab: tab,
            isProtected: isProtected
        )
            )
    }
}
