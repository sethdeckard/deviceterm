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
    public struct ListWindows: Codable, Sendable, Equatable {
        public let all: Bool

        public init(all: Bool) { self.all = all }
    }

    public struct ShowWindow: Codable, Sendable, Equatable {
        public let window: String?

        public init(window: String?) { self.window = window }
    }

    public struct OpenWindow: Codable, Sendable, Equatable {
        public init() {}
    }

    public struct FocusWindow: Codable, Sendable, Equatable {
        public let window: String?

        public init(window: String?) { self.window = window }
    }

    public struct CloseWindow: Codable, Sendable, Equatable {
        public let window: String?
        public let mode: WorkspaceCloseMode

        public init(window: String?, mode: WorkspaceCloseMode) {
            self.window = window
            self.mode = mode
        }
    }

    public struct ListTabs: Codable, Sendable, Equatable {
        public let window: String?
        public let all: Bool

        public init(window: String?, all: Bool) {
            self.window = window
            self.all = all
        }
    }

    public struct ShowTab: Codable, Sendable, Equatable {
        public let tab: String?

        public init(tab: String?) { self.tab = tab }
    }

    public struct OpenTab: Codable, Sendable, Equatable {
        public let window: String?
        public let cwd: String?
        public let command: [String]?

        public init(
            window: String?,
            cwd: String?,
            command: [String]?
        ) {
            self.window = window
            self.cwd = cwd
            self.command = command
        }
    }

    public struct CloseTab: Codable, Sendable, Equatable {
        public let tab: String?
        public let mode: WorkspaceCloseMode

        public init(tab: String?, mode: WorkspaceCloseMode) {
            self.tab = tab
            self.mode = mode
        }
    }

    public struct RenameTab: Codable, Sendable, Equatable {
        public let tab: String?
        public let name: String?

        public init(tab: String?, name: String?) {
            self.tab = tab
            self.name = name
        }
    }

    public struct FocusTab: Codable, Sendable, Equatable {
        public let tab: String?

        public init(tab: String?) { self.tab = tab }
    }

    public struct MoveTab: Codable, Sendable, Equatable {
        public let tab: String?
        public let window: String
        public let index: Int?

        public init(tab: String?, window: String, index: Int?) {
            self.tab = tab
            self.window = window
            self.index = index
        }
    }

    public struct SetTabProtection: Codable, Sendable, Equatable {
        public let tab: String?

        public init(tab: String?) { self.tab = tab }
    }

    public struct ListPanes: Codable, Sendable, Equatable {
        public let tab: String?

        public init(tab: String?) { self.tab = tab }
    }

    public struct ShowPane: Codable, Sendable, Equatable {
        public let pane: String?

        public init(pane: String?) { self.pane = pane }
    }

    public struct SplitPane: Codable, Sendable, Equatable {
        public let pane: String?
        public let direction: WorkspaceSplitDirection

        public init(pane: String?, direction: WorkspaceSplitDirection) {
            self.pane = pane
            self.direction = direction
        }
    }

    public struct FocusPane: Codable, Sendable, Equatable {
        public let pane: String?

        public init(pane: String?) { self.pane = pane }
    }

    public struct ClosePane: Codable, Sendable, Equatable {
        public let pane: String?
        public let mode: WorkspaceCloseMode?

        public init(pane: String?, mode: WorkspaceCloseMode?) {
            self.pane = pane
            self.mode = mode
        }
    }

    public struct RenamePane: Codable, Sendable, Equatable {
        public let pane: String?
        public let name: String?

        public init(pane: String?, name: String?) {
            self.pane = pane
            self.name = name
        }
    }

    public struct SendPaneInput: Codable, Sendable, Equatable {
        public let pane: String
        public let text: String
        public let typeDelayMs: Int?

        public init(pane: String, text: String, typeDelayMs: Int?) {
            self.pane = pane
            self.text = text
            self.typeDelayMs = typeDelayMs
        }
    }

    public struct CapturePaneText: Codable, Sendable, Equatable {
        public let pane: String

        public init(pane: String) { self.pane = pane }
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
}
