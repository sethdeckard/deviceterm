// SPDX-License-Identifier: GPL-3.0-or-later
//
// Receipt: per-command JSON shapes for `--json` mode.
//
// Each input command gets its own Encodable struct so the JSON shape
// is enforced at compile time and the test surface is one
// `JSONEncoder` invocation per command. Fields mirror the
// `Echo.ok(...)` receipt line: every command's JSON object has the
// stable `{ok, udid, paneId}` prefix plus the per-command fields the
// human receipt would show.
//
// **nil handling**: synthesized Encodable uses `encodeIfPresent`
// for Optional fields, so a nil value omits the key entirely rather
// than emitting JSON `null`. This matches the common JSON-API
// convention (jq `has(\"key\")` is the canonical absence check).
// Consequences:
//   - Older-daemon skew on swipe → `dispatched`/`steps`/`durationMs`
//     keys absent. Consumers checking `has("dispatched")` see the
//     skew explicitly.
//   - `tabs list` rows with no `name` / `label` omit those keys;
//     the `current` boolean is always present.
//   - `shortId` is omitted when the daemon predates the identifier
//     model; current daemons always emit it.
//
// All structs encode with `JSONEncoder.OutputFormatting.sortedKeys`
// in production so test assertions are byte-stable across Swift
// versions and platforms.

import Foundation

public enum Receipt {
    public struct Tap: Encodable, Sendable {
        public let ok = true
        public let udid: String
        public let paneId: String
        public let shortId: String?
        public let x: Double
        public let y: Double
    }

    public struct Swipe: Encodable, Sendable {
        public let ok = true
        public let udid: String
        public let paneId: String
        public let shortId: String?
        /// `tap` (collapsed sub-frame) or `drag`. Nil from older
        /// daemons that predate the dispatched echo (e.g. mid-Sparkle
        /// update window).
        public let dispatched: String?
        public let steps: Int?
        public let durationMs: Int?
    }

    public struct LongPress: Encodable, Sendable {
        public let ok = true
        public let udid: String
        public let paneId: String
        public let shortId: String?
        public let x: Double
        public let y: Double
        public let durationMs: Int?
    }

    public struct Pinch: Encodable, Sendable {
        public let ok = true
        public let udid: String
        public let paneId: String
        public let shortId: String?
        /// The eight pinch coords are intentionally omitted: they
        /// echo what the caller sent and make the JSON object
        /// unreadable. `durationMs` is the only tunable agents
        /// iterate on; coords stay implicit.
        public let durationMs: Int?
    }

    public struct Button: Encodable, Sendable {
        public let ok = true
        public let udid: String
        public let paneId: String
        public let shortId: String?
        public let button: String
    }

    public struct Key: Encodable, Sendable {
        public let ok = true
        public let udid: String
        public let paneId: String
        public let shortId: String?
        /// `0x`-prefixed hex string mirroring the parser's accepted
        /// form and the human echo output; agents reading the JSON
        /// can round-trip the field straight back into a subsequent
        /// `deviceterm key <keyCode>` invocation.
        public let keyCode: String
        public let down: Bool
    }

    public struct Text: Encodable, Sendable {
        public let ok = true
        public let udid: String
        public let paneId: String
        public let shortId: String?
        /// UTF-8 byte count of the typed string. The receipt carries
        /// the count rather than the text: receipts get piped to
        /// logs and jq, and typed input can carry secrets.
        public let bytes: Int
    }

    public struct Rotate: Encodable, Sendable {
        public let ok = true
        public let udid: String
        public let paneId: String
        public let shortId: String?
        /// Exactly one of `orientation` / `direction` is present,
        /// echoing the form the command was given. A relative rotate
        /// resolves against an orientation only the daemon holds, so the
        /// receipt reports the direction asked for rather than a
        /// resulting orientation it would have to guess at.
        public let orientation: String?
        public let direction: String?
    }

    public struct Crown: Encodable, Sendable {
        public let ok = true
        public let udid: String
        public let paneId: String
        public let shortId: String?
        public let delta: Double
        /// `velocity` is decoded at the daemon but silently ignored
        /// (the SimulatorKit crown builder takes only a delta); it's
        /// surfaced here as `null` when omitted so an agent
        /// inspecting the receipt can confirm what it sent vs. what
        /// the daemon used.
        public let velocity: Double?
        public let durationMs: Int?
    }

    /// One row of `tabs list --json`. Carries the five human-column
    /// values plus JSON-only `displayTitle`; the `current` boolean
    /// replaces the `*` / space marker. `tabs current --json` emits a
    /// single instance of this same type: JSON consumers can decode
    /// either list-mode or single-mode output with one struct.
    ///
    /// `displayTitle` is JSON-only. The human columns are a pinned
    /// tab-separated shape a sixth column would break. It is the GUI's
    /// live tab label (the shell's OSC title, a manual rename) in the
    /// normalized, bounded form the daemon holds, so unlike `shortId` /
    /// `name` it is not an identifier and never resolves a `--tab <ref>`.
    /// Null when the GUI hasn't pushed one, when the label says nothing
    /// `name` doesn't, and for the non-primary terminals of a split tab.
    public struct TabsListRow: Encodable, Sendable {
        public let current: Bool
        public let shortId: String?
        public let name: String?
        public let displayTitle: String?
        public let sessionId: String
        public let label: String?
    }

    // MARK: - Workspace verb receipts
    //
    // One per mutating workspace verb (`tab` / `pane` / `window`
    // sub-commands). Mirrors the `ok target=…` echo line in JSON
    // form so an agent decoding `--json` output sees the same
    // fields. `ok` is always `true`; the daemon would surface
    // errors as stderr lines (with a non-zero exit) before any
    // receipt printed.

    public struct TabOpen: Encodable, Sendable {
        public let ok = true
        /// Echo of the requested window ref (`"current"` when the
        /// caller omitted `--window`). The new tab's session id
        /// isn't surfaced here: the GUI mints it asynchronously,
        /// so the open is fire-and-forget.
        public let window: String
    }

    public struct TabClose: Encodable, Sendable {
        public let ok = true
        public let tab: String
        public let mode: String
    }

    public struct TabRename: Encodable, Sendable {
        public let ok = true
        public let tab: String
        /// nil when the caller passed no positional name (= restore
        /// the automatic title); the encoded JSON omits the key
        /// entirely in that case.
        public let name: String?
    }

    public struct TabSelect: Encodable, Sendable {
        public let ok = true
        public let tab: String
    }

    public struct TabMove: Encodable, Sendable {
        public let ok = true
        public let tab: String
        /// Omitted from the JSON when the caller passed no `--to`.
        public let toIndex: Int?
        /// Omitted when the move stays in the same window (no `--to-window`).
        public let toWindow: String?
    }

    public struct PaneOpenTerminal: Encodable, Sendable {
        public let ok = true
        public let tab: String
    }

    public struct PaneClose: Encodable, Sendable {
        public let ok = true
        public let pane: String
        public let mode: String
    }

    public struct PaneRename: Encodable, Sendable {
        public let ok = true
        public let pane: String
        public let name: String?
    }

    public struct PaneMove: Encodable, Sendable {
        public let ok = true
        public let pane: String
        public let toTab: String
    }

    public struct DeviceAttach: Encodable, Sendable {
        public let ok = true
        /// The resolved device identity: a sim UDID or a physical
        /// deviceId.
        public let target: String
        /// `sim` or `device`.
        public let kind: String
    }

    public struct WindowOpen: Encodable, Sendable {
        public let ok = true
    }

    public struct WindowClose: Encodable, Sendable {
        public let ok = true
        public let window: String
        public let mode: String
    }

    public struct WindowFocus: Encodable, Sendable {
        public let ok = true
        public let window: String
    }

    /// Receipt for `deviceterm tab send-input`. `bytes` is the UTF-8
    /// length of the dispatched text, same rule as the `text`
    /// verb: report the action, never the payload.
    /// `typeDelayMillis` echoes the pacing when the caller animated
    /// the injection (omitted for an instant one-shot).
    public struct TabSendInput: Encodable, Sendable {
        public let ok = true
        public let tab: String
        public let bytes: Int
        public let typeDelayMillis: Int?

        public init(tab: String, bytes: Int, typeDelayMillis: Int? = nil) {
            self.tab = tab
            self.bytes = bytes
            self.typeDelayMillis = typeDelayMillis
        }
    }

    /// Receipt for `deviceterm tab set-protected`. Reports the resolved tab
    /// label, the new protection state, and whether the daemon *committed* it.
    /// `committed == false` means the requested state is not yet confirmed
    /// and the GUI may still be converging; it does not prove daemon
    /// acceptance. A definite rejection surfaces as a command failure,
    /// never this receipt.
    public struct TabSetProtected: Encodable, Sendable {
        public let ok = true
        public let tab: String
        public let isProtected: Bool
        public let committed: Bool
    }
}
