// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Strongly-typed param structs, one per `AppCommandKind`, namespaced
/// under `AppCommandParams` rather than left free at module scope.
///
/// Each struct exposes an explicit `public init(...)` so cross-module
/// callers (the CLI, tests in other modules) can construct them
/// directly, since Swift only synthesizes an `internal` memberwise init
/// for `public` structs with `public let` members.
public enum AppCommandParams {
    public struct OpenTab: Codable, Sendable, Equatable {
        /// Optional window ref, encoded shape per `Wire.WindowRef`.
        public let window: Wire.WindowRef?
        /// `"agent"` or `"automation"`. Always agent over the
        /// CLI back-channel: no CLI verb emits automation. The
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

    public struct SetTabProtected: Codable, Sendable, Equatable {
        public let tab: Wire.TabRef
        public let isProtected: Bool

        public init(tab: Wire.TabRef, isProtected: Bool) {
            self.tab = tab
            self.isProtected = isProtected
        }
    }
}
