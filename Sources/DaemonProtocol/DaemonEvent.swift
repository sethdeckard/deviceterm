// SPDX-License-Identifier: GPL-3.0-or-later
//
// DaemonEvent: the on-wire shape of daemon state-change events
// (`deviceterm events` / `daemon.events`). The wire shape is the same
// regardless of audience; `daemon.events` delivery is session-scoped
// (see the daemon's EventBroker), but that's a routing concern, not a
// field on this struct.
//
// Flat struct with a `type` discriminator and per-type Optional
// fields. Synthesized Encodable's `encodeIfPresent` omits nil fields,
// so each event lands on the wire as a compact JSON object with only
// the keys its `type` populates. Decoding a payload with unknown keys
// ignores them, the same skew-tolerance posture as the rest of the wire
// surface.
//
// Why flat instead of an enum-with-associated-values: a flat struct
// gives free synthesized Codable + a predictable jq-friendly schema
// (`.type`, `.ts`, `.paneId`, …) without per-case CodingKeys.
// Consumers select event kinds with
// `jq 'select(.type == "pane.stateChanged")'`.

import Foundation

public struct DaemonEvent: Codable, Sendable, Equatable {
    /// Discriminator. See `DaemonEventType` for the canonical
    /// values shipped. Future event types can extend the
    /// constant set without a wire-version bump (synthesized
    /// Codable tolerates unknown values; consumers just won't
    /// match their `select(.type == …)` filters).
    public let type: String

    /// ISO-8601 UTC timestamp; produced via `DaemonEvent.now()`
    /// on the daemon side. Present on every event.
    public let ts: String

    // MARK: - Per-event-kind Optional fields

    /// `pane.stateChanged` only: the pane's UUID.
    public let paneId: String?
    /// `pane.stateChanged`, `device.booted`, `device.shutdown`:
    /// the sim's UDID.
    public let udid: String?
    /// `pane.stateChanged` only: `booting` / `rendering` /
    /// `shutdown`.
    public let state: String?
    /// `session.created`, `session.closed`: the session UUID.
    public let sessionId: String?
    /// `session.created` only: the Crockford short_id.
    public let shortId: String?
    /// `session.created` only: the optional session name.
    public let name: String?

    public init(
        type: String,
        ts: String,
        paneId: String? = nil,
        udid: String? = nil,
        state: String? = nil,
        sessionId: String? = nil,
        shortId: String? = nil,
        name: String? = nil
    ) {
        self.type = type
        self.ts = ts
        self.paneId = paneId
        self.udid = udid
        self.state = state
        self.sessionId = sessionId
        self.shortId = shortId
        self.name = name
    }
}

public extension DaemonEvent {
    /// ISO-8601 UTC timestamp at the current instant. Daemon-side
    /// factories call this so every event carries `ts`. Tests inject
    /// a fixed instant by passing `ts:` explicitly.
    static func now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    // MARK: - Factories

    static func paneStateChanged(
        paneId: String,
        udid: String,
        state: String,
        ts: String = DaemonEvent.now()
    ) -> DaemonEvent {
        DaemonEvent(
            type: DaemonEventType.paneStateChanged,
            ts: ts,
            paneId: paneId,
            udid: udid,
            state: state
        )
    }

    static func deviceBooted(
        udid: String,
        ts: String = DaemonEvent.now()
    ) -> DaemonEvent {
        DaemonEvent(
            type: DaemonEventType.deviceBooted,
            ts: ts,
            udid: udid
        )
    }

    static func deviceShutdown(
        udid: String,
        ts: String = DaemonEvent.now()
    ) -> DaemonEvent {
        DaemonEvent(
            type: DaemonEventType.deviceShutdown,
            ts: ts,
            udid: udid
        )
    }

    static func sessionCreated(
        sessionId: String,
        shortId: String,
        name: String?,
        ts: String = DaemonEvent.now()
    ) -> DaemonEvent {
        DaemonEvent(
            type: DaemonEventType.sessionCreated,
            ts: ts,
            sessionId: sessionId,
            shortId: shortId,
            name: name
        )
    }

    static func sessionClosed(
        sessionId: String,
        ts: String = DaemonEvent.now()
    ) -> DaemonEvent {
        DaemonEvent(
            type: DaemonEventType.sessionClosed,
            ts: ts,
            sessionId: sessionId
        )
    }
}
