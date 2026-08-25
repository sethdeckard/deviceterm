// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

// DaemonEvent: the wire shape for `daemon.events`.
//
// Pins the per-type field set + the synthesized encodeIfPresent
// behavior (nil fields are omitted, matching the wire's stable-shape
// convention). Tests are byte-stable via JSONEncoder's sortedKeys.

private func encode(_ event: DaemonEvent) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(event)
    return try #require(String(data: data, encoding: .utf8))
}

// MARK: - paneStateChanged

@Test
func paneStateChangedCarriesFiveFields() throws {
    let event = DaemonEvent.paneStateChanged(
        paneId: "AAAA-PID",
        udid: "DEAD-UDID",
        state: "rendering",
        ts: "2026-05-30T18:24:00Z"
    )
    let json = try encode(event)
    let expected = #"{"paneId":"AAAA-PID","state":"rendering","#
        + #""ts":"2026-05-30T18:24:00Z","type":"pane.stateChanged","#
        + #""udid":"DEAD-UDID"}"#
    #expect(json == expected)
}

@Test
func paneStateChangedHasCanonicalTypeName() {
    // Pin the discriminator string. Agents filter with
    // `jq 'select(.type == "pane.stateChanged")'`; the string
    // is load-bearing.
    let event = DaemonEvent.paneStateChanged(
        paneId: "P",
        udid: "U",
        state: "booting"
    )
    #expect(event.type == DaemonEventType.paneStateChanged)
    #expect(DaemonEventType.paneStateChanged == "pane.stateChanged")
}

// MARK: - deviceBooted / deviceShutdown

@Test
func deviceBootedCarriesUDIDOnly() throws {
    let event = DaemonEvent.deviceBooted(
        udid: "DEAD-UDID",
        ts: "2026-05-30T18:24:01Z"
    )
    let json = try encode(event)
    // Per the wire's nil-omission convention:
    // paneId/state/sessionId/shortId/name are all absent. Only ts
    // + type + udid are present.
    let expected = #"{"ts":"2026-05-30T18:24:01Z","#
        + #""type":"device.booted","udid":"DEAD-UDID"}"#
    #expect(json == expected)
}

@Test
func deviceShutdownHasCanonicalTypeName() throws {
    let event = DaemonEvent.deviceShutdown(
        udid: "DEAD-UDID",
        ts: "2026-05-30T18:32:00Z"
    )
    let json = try encode(event)
    #expect(json.contains(#""type":"device.shutdown""#))
    #expect(json.contains(#""udid":"DEAD-UDID""#))
    #expect(!json.contains("paneId"))
    #expect(!json.contains("state"))
}

// MARK: - sessionCreated / sessionClosed

@Test
func sessionCreatedCarriesSessionAndShortIdAndName() throws {
    let event = DaemonEvent.sessionCreated(
        sessionId: "11111111-1111-1111-1111-111111111111",
        shortId: "ab12cd",
        name: "feature-x",
        ts: "2026-05-30T18:24:00Z"
    )
    let json = try encode(event)
    #expect(json.contains(#""type":"session.created""#))
    #expect(json.contains(#""shortId":"ab12cd""#))
    #expect(json.contains(#""name":"feature-x""#))
    #expect(json.contains(#""sessionId":"11111111-1111-1111-1111-111111111111""#))
}

@Test
func sessionCreatedOmitsNilName() throws {
    let event = DaemonEvent.sessionCreated(
        sessionId: "11111111-1111-1111-1111-111111111111",
        shortId: "ab12cd",
        name: nil,
        ts: "2026-05-30T18:24:00Z"
    )
    let json = try encode(event)
    // nil `name` is omitted per the encodeIfPresent convention.
    #expect(!json.contains("\"name\""))
}

@Test
func sessionClosedCarriesSessionIdOnly() throws {
    let event = DaemonEvent.sessionClosed(
        sessionId: "11111111-1111-1111-1111-111111111111",
        ts: "2026-05-30T18:35:00Z"
    )
    let json = try encode(event)
    #expect(json.contains(#""type":"session.closed""#))
    #expect(json.contains(#""sessionId":"11111111-1111-1111-1111-111111111111""#))
    #expect(!json.contains("shortId"))
    #expect(!json.contains("name"))
}

// MARK: - Round-trip

@Test
func eventRoundTripsThroughCodable() throws {
    let original = DaemonEvent.paneStateChanged(
        paneId: "P",
        udid: "U",
        state: "rendering",
        ts: "2026-05-30T18:24:00Z"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(original)
    let decoded = try JSONDecoder().decode(DaemonEvent.self, from: data)
    #expect(decoded == original)
}

@Test
func nowReturnsISO8601Timestamp() {
    // Sanity: timestamps look like ISO-8601. Loose match (we don't
    // pin the exact format beyond "starts with year-month-day").
    let ts = DaemonEvent.now()
    #expect(ts.count >= 19)
    let prefix = ts.prefix(4)
    #expect(Int(prefix) != nil, "leading 4 chars should be a year: \(ts)")
}
