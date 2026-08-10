// SPDX-License-Identifier: GPL-3.0-or-later
//
// AppCommand: daemon-to-GUI back-channel request.
//
// The CLI's `deviceterm tab close --tab <ref>` (and the other
// workspace verbs) hits the daemon over the existing UDS RPC. For
// ops the
// daemon can't perform on its own (anything that mutates GUI tab /
// pane / window state), the daemon constructs an `AppCommand` and
// publishes it on the dedicated `app.commands` subscription that
// the GUI maintains at startup. The GUI translates the command into
// a `RouteIntent`, dispatches via `IntentDispatcher`, and acks the
// result via `app.commandResult`. The daemon correlates by
// `commandId` and resumes the original handler's continuation so
// the CLI caller gets a synchronous-feeling answer.
//
// Wire shape: a flat struct with a `kind` discriminator and a JSON
// `params` blob. Strong-typed per-kind params live in `AppCommand
// Params.<Kind>` sub-types; the GUI decodes the discriminator first,
// then the matching sub-type. New `kind` values can ship without a
// wire-version bump (newer GUI sees them; older one returns
// `unknownKind`).

import Foundation

/// Discriminator for `AppCommand.kind`. Stable strings so an older
/// GUI/CLI pair can read newer wire frames and fail gracefully.
public enum AppCommandKind: String, Codable, Sendable, CaseIterable {
    case tabOpen        = "tab.open"
    case tabClose       = "tab.close"
    case tabRename      = "tab.rename"
    case tabSelect      = "tab.select"
    case tabInfo        = "tab.info"
    /// `deviceterm tab move`: reorder within the window (`toIndex`) or
    /// relocate to another window (`toWindow`). The GUI reorders via
    /// `Route.reorderTab` or moves the live tab across windows.
    case tabMove        = "tab.move"
    case paneOpenTerminal = "pane.openTerminal"
    case paneClose      = "pane.close"
    case paneRename     = "pane.rename"
    case paneInfo       = "pane.info"
    case paneMove       = "pane.move"
    case paneAttach     = "pane.attach"
    case windowOpen     = "window.open"
    case windowClose    = "window.close"
    case windowFocus    = "window.focus"
    case windowsList    = "windows.list"
    /// `deviceterm tab send-input`: write into a tab's shell as
    /// though the user had typed. Grant-gated on the daemon side
    /// (a live orchestration grant, not a role); the GUI's
    /// IntentDispatcher writes through to the resolved tab's terminal
    /// surface via `IntentActionDelegate`.
    case tabSendInput = "tab.sendInput"
    /// `deviceterm tab capture`: read the resolved tab's currently-
    /// visible viewport as plain text. Grant-gated on the daemon side
    /// (a live orchestration grant, not a role); the GUI's
    /// IntentDispatcher reads via `IntentActionDelegate.captureTab` and
    /// returns the text as a `TabCapturePayload` on the back-channel result.
    case tabCapture = "tab.capture"
    /// `deviceterm tab set-private`: toggle the resolved tab's privacy
    /// flag. Ownership is enforced GUI-side by the origin/owner gate (an
    /// external caller may only target a tab it owns a terminal in); the
    /// mutation rides the `.validatedGUI` `session.setPrivateBatch`, so no
    /// raw CLI socket can flip it. When set, the tab disappears from
    /// `tabs.list` for every caller except the owner.
    case tabSetPrivate = "tab.setPrivate"
}

/// The wire envelope. `params` is the kind-specific Codable struct,
/// JSON-encoded on the daemon side and JSON-decoded on the GUI side
/// once the kind is read.
public struct AppCommand: Codable, Sendable, Equatable {
    /// Correlation id the daemon stamps into the published command
    /// and the GUI echoes back in `app.commandResult`. The daemon's
    /// AppCommandCoordinator keys its pending continuations by this.
    public let commandId: String

    /// What the GUI should do. See `AppCommandKind`.
    public let kind: AppCommandKind

    /// Caller's session id when the request came in over an
    /// authenticated UDS connection (CLI inside a tab). `nil` for
    /// daemon-wide callers, including an out-of-tab `windowsList --all`
    /// request (a stock-terminal CLI that can't invoke session-scoped
    /// verbs). The GUI builds the intent's
    /// `IntentOrigin.external(sessionID:)` from this, so
    /// `--tab current` / `--pane current` mean "the calling tab's
    /// tab/pane" and a foreign private tab stays opaque to the caller.
    public let originatingSessionId: String?

    /// Kind-specific params, encoded as a JSON object. The GUI side
    /// decodes into `AppCommandParams.<Kind>` after reading `kind`.
    public let params: Data

    public init(
        commandId: String,
        kind: AppCommandKind,
        originatingSessionId: String?,
        params: Data
    ) {
        self.commandId = commandId
        self.kind = kind
        self.originatingSessionId = originatingSessionId
        self.params = params
    }
}

/// Strong-typed param structs, one per `AppCommandKind`. Lives in
/// `AppCommandParams` rather than free at module scope so a reader
/// browsing the discriminator finds the matching shape next to it.
///
/// Each struct exposes an explicit `public init(...)` so cross-module
/// callers (the CLI, tests in other modules) can construct them
/// directly, since Swift only synthesizes an `internal` memberwise init
/// for `public` structs with `public let` members.
public enum AppCommandParams {
    public struct OpenTab: Codable, Sendable, Equatable {
        /// Optional window ref, encoded shape per `Wire.WindowRef`.
        public let window: Wire.WindowRef?
        /// `"agent"` or `"orchestrator"`. Always agent over the
        /// CLI back-channel: no CLI verb emits orchestrator. The
        /// field exists for menu / deep-link translators.
        public let role: String
        public let cwd: String?
        public let cmd: [String]?

        public init(
            window: Wire.WindowRef?,
            role: String,
            cwd: String?,
            cmd: [String]?
        ) {
            self.window = window
            self.role = role
            self.cwd = cwd
            self.cmd = cmd
        }
    }

    public struct CloseTab: Codable, Sendable, Equatable {
        public let tab: Wire.TabRef
        public let mode: String  // "detach" | "shutdown"

        public init(tab: Wire.TabRef, mode: String) {
            self.tab = tab
            self.mode = mode
        }
    }

    public struct RenameTab: Codable, Sendable, Equatable {
        public let tab: Wire.TabRef
        public let name: String?

        public init(tab: Wire.TabRef, name: String?) {
            self.tab = tab
            self.name = name
        }
    }

    public struct SelectTab: Codable, Sendable, Equatable {
        public let tab: Wire.TabRef

        public init(tab: Wire.TabRef) { self.tab = tab }
    }

    public struct TabInfo: Codable, Sendable, Equatable {
        public let tab: Wire.TabRef

        public init(tab: Wire.TabRef) { self.tab = tab }
    }

    public struct MoveTab: Codable, Sendable, Equatable {
        public let tab: Wire.TabRef
        /// Destination slot within the target window. Nil means "append
        /// at the end" (natural for a cross-window move with no explicit
        /// index).
        public let toIndex: Int?
        /// Destination window. Nil means "same window" (a pure reorder,
        /// where `toIndex` is required).
        public let toWindow: Wire.WindowRef?

        public init(tab: Wire.TabRef, toIndex: Int?, toWindow: Wire.WindowRef?) {
            self.tab = tab
            self.toIndex = toIndex
            self.toWindow = toWindow
        }
    }

    public struct OpenPaneTerminal: Codable, Sendable, Equatable {
        public let tab: Wire.TabRef?
        public let cwd: String?
        public let cmd: [String]?

        public init(
            tab: Wire.TabRef?,
            cwd: String?,
            cmd: [String]?
        ) {
            self.tab = tab
            self.cwd = cwd
            self.cmd = cmd
        }
    }

    public struct ClosePane: Codable, Sendable, Equatable {
        public let pane: Wire.PaneRef
        public let mode: String

        public init(pane: Wire.PaneRef, mode: String) {
            self.pane = pane
            self.mode = mode
        }
    }

    public struct RenamePane: Codable, Sendable, Equatable {
        public let pane: Wire.PaneRef
        public let name: String?

        public init(pane: Wire.PaneRef, name: String?) {
            self.pane = pane
            self.name = name
        }
    }

    public struct PaneInfo: Codable, Sendable, Equatable {
        public let pane: Wire.PaneRef

        public init(pane: Wire.PaneRef) { self.pane = pane }
    }

    public struct MovePane: Codable, Sendable, Equatable {
        public let pane: Wire.PaneRef
        public let toTab: Wire.TabRef

        public init(pane: Wire.PaneRef, toTab: Wire.TabRef) {
            self.pane = pane
            self.toTab = toTab
        }
    }

    /// Mount a device pane (`deviceterm device attach <ref>`). `target`
    /// carries the backend-neutral identity the CLI resolved the ref to:
    /// a `.sim(udid)` claims an orphan/booted simulator (the GUI's
    /// existing sim claim path); a `.device(deviceId)` mounts a
    /// physically-connected device. One published command serves both
    /// kinds; the GUI's translator dispatches the matching route.
    public struct PaneAttach: Codable, Sendable, Equatable {
        private enum CodingKeys: String, CodingKey {
            case target
            case relinkExisting
        }

        public let target: PaneTarget
        /// When the `.device` target is already mirrored in another tab,
        /// move it to the attaching session instead of rejecting. The
        /// shim's contextual auto-attach sets this, since a `devicectl
        /// install`/`launch` is strong evidence the device context moved
        /// to the calling tab. Explicit `deviceterm device attach` leaves it
        /// false, so a CLI relink can't silently steal a visible pane from
        /// another tab (cross-tab relocation stays a deliberate GUI drag).
        /// Ignored for the `.sim` claim path.
        public let relinkExisting: Bool

        public init(target: PaneTarget, relinkExisting: Bool = false) {
            self.target = target
            self.relinkExisting = relinkExisting
        }

        // Tolerant decode: an encoder that omits `relinkExisting` (or any
        // future caller built before this field existed) decodes as the
        // safe default of no relink. Encode stays synthesized.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            target = try container.decode(PaneTarget.self, forKey: .target)
            relinkExisting = try container.decodeIfPresent(
                Bool.self,
                forKey: .relinkExisting
            ) ?? false
        }
    }

    public struct OpenWindow: Codable, Sendable, Equatable {
        public init() {}
    }

    public struct CloseWindow: Codable, Sendable, Equatable {
        public let window: Wire.WindowRef
        public let mode: String

        public init(window: Wire.WindowRef, mode: String) {
            self.window = window
            self.mode = mode
        }
    }

    public struct FocusWindow: Codable, Sendable, Equatable {
        public let window: Wire.WindowRef

        public init(window: Wire.WindowRef) { self.window = window }
    }

    public struct WindowsList: Codable, Sendable, Equatable {
        public let all: Bool

        public init(all: Bool) { self.all = all }
    }

    public struct TabSendInput: Codable, Sendable, Equatable {
        public let tab: Wire.TabRef
        /// UTF-8 text to inject into the tab's shell. Engine
        /// processes it through the normal input pipeline, so
        /// control sequences (`\n`, `\r`, `\x03`, …) work the same
        /// as if the user had typed them at the keyboard.
        public let text: String
        /// Optional per-character typing delay in milliseconds. When
        /// `nil` or `0` the text is delivered in one shot (the
        /// default, backward-compatible behavior). When positive the
        /// GUI animates the injection one `Character` at a time with
        /// this delay between them, so a screencast shows the command
        /// being "typed" rather than pasted. The call is non-blocking:
        /// it returns once the animation is enqueued, so the
        /// back-channel ack isn't held for the typing duration.
        /// Concurrent paced calls to one tab type out in order.
        public let typeDelayMillis: Int?

        public init(
            tab: Wire.TabRef,
            text: String,
            typeDelayMillis: Int? = nil
        ) {
            self.tab = tab
            self.text = text
            self.typeDelayMillis = typeDelayMillis
        }
    }

    public struct TabCapture: Codable, Sendable, Equatable {
        public let tab: Wire.TabRef

        public init(tab: Wire.TabRef) { self.tab = tab }
    }

    public struct SetTabPrivate: Codable, Sendable, Equatable {
        public let tab: Wire.TabRef
        public let isPrivate: Bool

        public init(tab: Wire.TabRef, isPrivate: Bool) {
            self.tab = tab
            self.isPrivate = isPrivate
        }
    }
}

/// Wire-format ref types. Two-key shape (`type` discriminator +
/// optional `value`) for forward-compat, so a future ref kind can
/// extend the enum without breaking older decoders.
public enum Wire {
    public struct TabRef: Codable, Sendable, Equatable {
        public let type: String      // "current" | "sessionId" | "shortId" | "name"
        public let value: String?

        public init(type: String, value: String?) {
            self.type = type; self.value = value
        }
    }

    public struct PaneRef: Codable, Sendable, Equatable {
        public let type: String      // "current" | "paneId" | "udid" | "shortId"
        public let value: String?

        public init(type: String, value: String?) {
            self.type = type; self.value = value
        }
    }

    public struct WindowRef: Codable, Sendable, Equatable {
        public let type: String      // "current" | "index" | "keyed"
        public let value: String?    // "index" → stringified Int

        public init(type: String, value: String?) {
            self.type = type; self.value = value
        }
    }
}
