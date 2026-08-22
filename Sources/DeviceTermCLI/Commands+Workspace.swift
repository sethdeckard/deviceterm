// SPDX-License-Identifier: GPL-3.0-or-later
//
// Workspace command family: tab / pane / device / window parsing and
// request building, split out of Commands.swift to keep that file focused
// on the shared parse core. `parse(_:)` (in Commands.swift) delegates the
// workspace verbs to the `parse*Subcommand` helpers here; the `*Request`
// builders encode the matching `AppCommandParams` struct for the daemon's
// `app.commands` back-channel.
//
// This is a behavior-grouping extension, not a conformance split. The
// shared `request(method:body:)` helper and the `parse*Subcommand` entries
// were relaxed from `private` to `internal` in Commands.swift so this file
// can reach them.

import DaemonProtocol
import Foundation

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

    // MARK: - Workspace sub-command parsers

    /// `deviceterm tab <open|close|rename|select|info> [flags] [name]`.
    ///
    /// `escapedCount` carries how much of the positional tail arrived
    /// after a `--` terminator, which `rename` needs to tell a help
    /// request from a literal name.
    static func parseTabSubcommand(
        positionals pos: [String],
        flags: [String: String],
        escapedCount: Int
    ) -> CLICommand {
        guard let sub = pos.first else {
            return .usage(
                message:
                "deviceterm: 'tab' supports: open, close, rename, select, info, move, "
                + "send-input, capture, set-private"
                )
        }
        switch sub {
        case "open":
            // Any positional tail after the sub-verb is unrecognized
            // Flag-shaped tokens get split into valued/presence
            // flags up front, so a leftover positional means the
            // user typed something the parser doesn't understand.
            let extras = Array(pos.dropFirst())
            if !extras.isEmpty {
                return .usage(
                    message:
                    "usage: deviceterm tab open [--window <ref>] "
                    + "[--cwd <path>] [--cmd '<cmd>']"
                    )
            }
            let window = flags["window"].map(parseWindowRef)
            return .tabOpen(window: window, cwd: flags["cwd"], cmd: flags["cmd"])

        case "capture":
            // `deviceterm tab capture [--tab <ref>]`:
            // automation-only. No positional tail; any extras
            // are rejected so a future flag isn't silently
            // swallowed.
            let extras = Array(pos.dropFirst())
            if !extras.isEmpty {
                return .usage(
                    message:
                    "usage: deviceterm tab capture [--tab <ref>]"
                    )
            }
            return .tabCapture(tab: parseTabRef(flags["tab"]))

        case "send-input":
            // `deviceterm tab send-input [--tab <ref>]
            // [--type-delay <ms>] <text...>`: automation-only. The
            // text is the positional tail after `send-input`; joined
            // with spaces so quoted args carrying spaces stay intact
            // (mirrors the `text` verb convention). C-style escapes
            // (`\n`, `\r`, `\xNN`, …) are decoded to their byte values
            // so the documented examples drive the shell. An empty
            // text is a usage error since the verb has no other
            // sensible interpretation.
            let tail = Array(pos.dropFirst()).joined(separator: " ")
            guard !tail.isEmpty else {
                return .usage(
                    message:
                    "usage: deviceterm tab send-input [--tab <ref>] [--type-delay <ms>] <text>"
                    )
            }
            // `--type-delay <ms>` (optional) animates the injection one
            // character at a time for screencasts. A malformed or
            // negative value is a usage error rather than a silent
            // fallback to instant delivery. The value is capped at the
            // GUI's ceiling so an absurd delay can't overflow any
            // downstream arithmetic or wedge the pane; 1 s/char is
            // already the slowest sensible typing speed.
            var typeDelay: Int?
            if let raw = flags["type-delay"] {
                guard let millis = Int(raw), millis >= 0 else {
                    return .usage(
                        message:
                        "deviceterm: --type-delay expects a non-negative integer (milliseconds)"
                        )
                }
                typeDelay = min(millis, maxTypeDelayMillis)
            }
            return .tabSendInput(
                tab: parseTabRef(flags["tab"]),
                text: decodeEscapes(tail),
                typeDelay: typeDelay
            )

        case "close":
            let ref = parseTabRef(flags["tab"])
            let mode = parseCloseMode(flags["mode"])
            return .tabClose(tab: ref, mode: mode)

        case "rename":
            let ref = parseTabRef(flags["tab"])
            // Positional tail (after the sub-verb) is the new name.
            // Joined with spaces so quoted args carrying spaces stay
            // intact, matching `text`'s convention.
            let tail = Array(pos.dropFirst())
            if isHelpRequest(nameTail: tail, escapedCount: escapedCount) {
                return .usage(
                    message:
                    "usage: deviceterm tab rename [--tab <ref>] [<name>]"
                    )
            }
            let trimmed = tail.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            let name: String? = trimmed.isEmpty ? nil : trimmed
            return .tabRename(tab: ref, name: name)

        case "select":
            return .tabSelect(tab: parseTabRef(flags["tab"]))

        case "info":
            return .tabInfo(tab: parseTabRef(flags["tab"]))

        case "move":
            // `deviceterm tab move [--tab <ref>] [--to <index>]
            // [--to-window <ref>]`. No positional tail. Requires at
            // least one destination flag; `--to` must parse as an Int.
            let extras = Array(pos.dropFirst())
            if !extras.isEmpty {
                return .usage(
                    message:
                    "usage: deviceterm tab move [--tab <ref>] [--to <index>] [--to-window <ref>]"
                    )
            }
            var toIndex: Int?
            if let raw = flags["to"] {
                guard let parsed = Int(raw) else {
                    return .usage(
                        message:
                        "deviceterm: 'tab move --to' expects an integer index; got '\(raw)'"
                        )
                }
                toIndex = parsed
            }
            let toWindow = flags["to-window"].map(parseWindowRef)
            if toIndex == nil, toWindow == nil {
                return .usage(
                    message:
                    "usage: deviceterm tab move [--tab <ref>] --to <index> | --to-window <ref>"
                    )
            }
            return .tabMove(
                tab: parseTabRef(flags["tab"]),
                toIndex: toIndex,
                toWindow: toWindow
            )

        case "set-private":
            // `deviceterm tab set-private <true|false> [--tab <ref>]`:
            // owner-only, enforced GUI-side by the origin gate (the
            // mutation itself rides the validated-GUI batch RPC). The
            // boolean is the positional after `set-private`; reject
            // anything that isn't a recognized flag value so a typo
            // doesn't silently default.
            guard let raw = pos.dropFirst().first else {
                return .usage(
                    message:
                    "usage: deviceterm tab set-private <true|false> [--tab <ref>]"
                    )
            }
            let parsed: Bool
            switch raw.lowercased() {
            case "true", "yes", "on", "1":
                parsed = true

            case "false", "no", "off", "0":
                parsed = false

            default:
                return .usage(
                    message:
                    "deviceterm: 'tab set-private' expects true or false; got '\(raw)'"
                    )
            }
            return .tabSetPrivate(
                tab: parseTabRef(flags["tab"]),
                isPrivate: parsed
            )

        default:
            return .usage(
                message:
                "deviceterm: 'tab' supports: open, close, rename, select, info, move, "
                + "send-input, capture, set-private"
                )
        }
    }

    /// `deviceterm pane <open|close|rename|info|move> [flags] [name]`.
    /// Note: the former `pane attach` subverb is retired;
    /// `deviceterm device attach <ref>` is the one explicit-attach story.
    ///
    /// `escapedCount` serves `rename`, as it does for `tab`.
    static func parsePaneSubcommand(
        positionals pos: [String],
        flags: [String: String],
        escapedCount: Int
    ) -> CLICommand {
        guard let sub = pos.first else {
            return .usage(
                message:
                "deviceterm: 'pane' supports: open, close, rename, info, move"
                )
        }
        switch sub {
        case "open":
            // `--terminal` is a presence-only marker that falls
            // through the flag splitter as a positional. Require
            // exactly that and reject any other positional tail,
            // valued flags (`--cwd`, `--cmd`, `--tab`) land in
            // `flags` separately. `pane open --simulator` etc. land
            // as recognized variants later.
            let extras = Array(pos.dropFirst())
            guard extras == ["--terminal"] else {
                return .usage(
                    message:
                    "usage: deviceterm pane open --terminal [--tab <ref>] "
                    + "[--cwd <path>] [--cmd '<cmd>']"
                    )
            }
            let tab = flags["tab"].map(parseTabRef)
            return .paneOpenTerminal(
                tab: tab,
                cwd: flags["cwd"],
                cmd: flags["cmd"]
            )

        case "close":
            let ref = parsePaneRef(flags["pane"])
            let mode = parseCloseMode(flags["mode"])
            return .paneClose(pane: ref, mode: mode)

        case "rename":
            let ref = parsePaneRef(flags["pane"])
            let tail = Array(pos.dropFirst())
            if isHelpRequest(nameTail: tail, escapedCount: escapedCount) {
                return .usage(
                    message:
                    "usage: deviceterm pane rename [--pane <ref>] [<name>]"
                    )
            }
            let trimmed = tail.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            let name: String? = trimmed.isEmpty ? nil : trimmed
            return .paneRename(pane: ref, name: name)

        case "info":
            return .paneInfo(pane: parsePaneRef(flags["pane"]))

        case "move":
            guard let toTabRaw = flags["to-tab"], !toTabRaw.isEmpty else {
                return .usage(
                    message:
                    "usage: deviceterm pane move [--pane <ref>] --to-tab <ref>"
                    )
            }
            let ref = parsePaneRef(flags["pane"])
            return .paneMove(pane: ref, toTab: parseTabRef(toTabRaw))

        default:
            return .usage(
                message:
                "deviceterm: 'pane' supports: open, close, rename, info, move"
                )
        }
    }

    /// `deviceterm device attach <ref>`. The `<ref>` resolves against the
    /// `devices.list` roster at dispatch time (sim UDID, physical
    /// deviceId, or device name); the parser only captures it.
    static func parseDeviceSubcommand(
        positionals pos: [String]
    ) -> CLICommand {
        guard let sub = pos.first else {
            return .usage(message: "deviceterm: 'device' supports: attach")
        }
        switch sub {
        case "attach":
            guard let ref = pos.dropFirst().first, !ref.isEmpty,
                pos.count == 2 else {
                return .usage(message: "usage: deviceterm device attach <ref>")
            }
            return .deviceAttach(ref: ref)

        default:
            return .usage(message: "deviceterm: 'device' supports: attach")
        }
    }

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

    /// `deviceterm window <open|close|focus> [flags]`.
    static func parseWindowSubcommand(
        positionals pos: [String],
        flags: [String: String]
    ) -> CLICommand {
        guard let sub = pos.first else {
            return .usage(
                message:
                "deviceterm: 'window' supports: open, close, focus"
                )
        }
        switch sub {
        case "open":
            return .windowOpen

        case "close":
            let ref = parseWindowRef(flags["window"])
            let mode = parseCloseMode(flags["mode"])
            return .windowClose(window: ref, mode: mode)

        case "focus":
            return .windowFocus(window: parseWindowRef(flags["window"]))

        default:
            return .usage(
                message:
                "deviceterm: 'window' supports: open, close, focus"
                )
        }
    }

    /// `deviceterm windows list [--all]`.
    static func parseWindowsSubcommand(
        positionals pos: [String]
    ) -> CLICommand {
        guard pos.first == "list" else {
            return .usage(message: "deviceterm: 'windows' supports: list")
        }
        // `--all` falls through to the positional list since the
        // flag splitter treats it as a no-value flag; presence is
        // the signal.
        let all = pos.dropFirst().contains("--all")
        return .windowsList(all: all)
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

    public static func tabSetPrivateRequest(
        tab: Wire.TabRef,
        isPrivate: Bool
    ) throws -> RPCEnvelope {
        try request(
            method: .tabSetPrivate,
            body: AppCommandParams.SetTabPrivate(
            tab: tab,
            isPrivate: isPrivate
        )
            )
    }
}
