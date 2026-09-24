// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Per-command JSON shapes for `--json` mode.
///
/// Each input command gets its own Encodable struct so the JSON shape
/// is enforced at compile time and the test surface is one
/// `JSONEncoder` invocation per command. Every command's JSON object keeps
/// the stable `{ok, udid, paneId}` prefix; the per-command fields need not
/// match the human receipt. The echo line's `pane` is `paneId` and `shortId`
/// here, its `matches` is `matchCount`, and a selector-driven tap carries a
/// label and identifier the space-separated line cannot quote at all.
///
/// **nil handling**: synthesized Encodable uses `encodeIfPresent`
/// for Optional fields, so a nil value omits the key entirely rather
/// than emitting JSON `null`. This matches the common JSON-API
/// convention (jq `has(\"key\")` is the canonical absence check).
/// Consequences:
///   - Older-daemon skew on swipe → `dispatched`/`steps`/`durationMs`
///     keys absent. Consumers checking `has("dispatched")` see the
///     skew explicitly.
///   - `shortId` stays optional for decode compatibility with the
///     pre-identifier response shape.
///
/// All structs encode with `JSONEncoder.OutputFormatting.sortedKeys`
/// in production so test assertions are byte-stable across Swift
/// versions and platforms.
public enum Receipt {
    public struct Tap: Encodable, Sendable {
        public let ok = true
        public let udid: String
        public let paneId: String
        public let shortId: String?
        public let x: Double
        public let y: Double
        /// The element a selector-driven tap (`tap --label` /
        /// `tap --identifier`) resolved its coordinate from, and what the
        /// wait cost to find it. A tap handed its coordinates omits all five,
        /// so its receipt keeps the shape it has.
        ///
        /// `role`, `label`, and `identifier` are each absent when the element
        /// carried no such attribute. `matchCount` counts every element the
        /// query matched, not the candidates selection considered.
        public let role: String?
        public let label: String?
        public let identifier: String?
        public let matchCount: Int?
        public let elapsedMs: Int?

        public init(
            udid: String,
            paneId: String,
            shortId: String?,
            x: Double,
            y: Double,
            role: String? = nil,
            label: String? = nil,
            identifier: String? = nil,
            matchCount: Int? = nil,
            elapsedMs: Int? = nil
        ) {
            self.udid = udid
            self.paneId = paneId
            self.shortId = shortId
            self.x = x
            self.y = y
            self.role = role
            self.label = label
            self.identifier = identifier
            self.matchCount = matchCount
            self.elapsedMs = elapsedMs
        }
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
        /// echoing the form the command was given. The confirmed absolute
        /// outcome is reported separately below.
        public let orientation: String?
        public let direction: String?
        /// The absolute orientation the daemon resolved the request to.
        public let targetOrientation: String
        /// The orientation that confirmed the request.
        public let observedOrientation: String
    }

    public struct Fold: Encodable, Sendable {
        public let ok = true
        public let udid: String
        public let paneId: String
        public let shortId: String?
        /// The angle actually sent. A named posture is resolved before the
        /// request, so the receipt reports degrees whichever form was typed
        /// and an agent can read back exactly what the device was given.
        public let degrees: Double
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
}
