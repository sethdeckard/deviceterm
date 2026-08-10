// SPDX-License-Identifier: GPL-3.0-or-later

@testable import DaemonProtocol
import Foundation
import Testing

// SwipeAck pins the wire shape: `{"ok": true}` stays at the root so
// clients that only check `ok` keep working, and `dispatched`,
// `steps`, and `durationMs` surface the gesture kind the daemon
// actually dispatched. Without them the
// promotion is invisible: `deviceterm swipe` silently degrades to a
// tap-shaped wire payload at sub-frame durations, and a caller that
// asked for a drag has no way to tell it didn't get one.

@Test
func dispatchedDerivesFromStepCount() {
    #expect(SwipeAck(steps: 1, durationMs: 16).dispatched == .tap)
    #expect(SwipeAck(steps: 2, durationMs: 32).dispatched == .drag)
    #expect(SwipeAck(steps: 100, durationMs: 1_600).dispatched == .drag)
}

@Test
func encodesOkKeyForBackwardCompatibility() throws {
    let ack = SwipeAck(steps: 1, durationMs: 16)
    let data = try JSONEncoder().encode(ack)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    // The wire stays Codable + plain JSON; backward-compat with the
    // existing RPCAck (`{"ok": true}`) clients depends on the key
    // being `ok` (NOT `success`).
    #expect(json["ok"] as? Bool == true)
    #expect(json["dispatched"] as? String == "tap")
    #expect(json["steps"] as? Int == 1)
    #expect(json["durationMs"] as? Int == 16)
}

@Test
func encodesDragShape() throws {
    let ack = SwipeAck(steps: 12, durationMs: 200)
    let data = try JSONEncoder().encode(ack)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["dispatched"] as? String == "drag")
    #expect(json["steps"] as? Int == 12)
    #expect(json["durationMs"] as? Int == 200)
}

@Test
func roundTripsCleanly() throws {
    let original = SwipeAck(steps: 12, durationMs: 200)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(SwipeAck.self, from: data)
    #expect(decoded == original)
    #expect(decoded.success == true)
    #expect(decoded.dispatched == .drag)
}

@Test
func dispatchedEnumRawValuesAreStable() {
    // Stable wire strings: agents script against these.
    #expect(SwipeDispatch.tap.rawValue == "tap")
    #expect(SwipeDispatch.drag.rawValue == "drag")
}

@Test
func dispatchedDecodesFromBothShapes() throws {
    let tapJSON = Data(#"{"ok":true,"dispatched":"tap","steps":1,"durationMs":16}"#.utf8)
    let tapAck = try JSONDecoder().decode(SwipeAck.self, from: tapJSON)
    #expect(tapAck.dispatched == .tap)
    #expect(tapAck.steps == 1)
    #expect(tapAck.durationMs == 16)

    let dragJSON = Data(#"{"ok":true,"dispatched":"drag","steps":12,"durationMs":200}"#.utf8)
    let dragAck = try JSONDecoder().decode(SwipeAck.self, from: dragJSON)
    #expect(dragAck.dispatched == .drag)
    #expect(dragAck.steps == 12)
    #expect(dragAck.durationMs == 200)
}

// MARK: - Skew tolerance (new CLI ↔ older daemon)

@Test
func decodesBareOkAsOlderDaemonShape() throws {
    // Older daemons (pre-SwipeAck) replied with `{"ok": true}` for
    // swipe. A newer CLI must accept that without throwing: the
    // gesture was dispatched fine, the rich response just isn't
    // available. The CLI then falls back to bare `ok` on print.
    let bareOK = Data(#"{"ok":true}"#.utf8)
    let ack = try JSONDecoder().decode(SwipeAck.self, from: bareOK)
    #expect(ack.success == true)
    #expect(ack.dispatched == nil)
    #expect(ack.steps == nil)
    #expect(ack.durationMs == nil)
}

@Test
func newDaemonShapePopulatesTheCompleteTriple() throws {
    // Inverse direction: a new daemon's response always populates
    // all three extension fields. Asserts the atomic-triple contract
    // at the consumer test level (the wire decoder is tolerant of
    // partial responses, but a healthy new daemon never produces
    // them).
    let newShape = Data(#"{"ok":true,"dispatched":"drag","steps":12,"durationMs":200}"#.utf8)
    let ack = try JSONDecoder().decode(SwipeAck.self, from: newShape)
    #expect(ack.success == true)
    #expect(ack.dispatched != nil)
    #expect(ack.steps != nil)
    #expect(ack.durationMs != nil)
}

@Test
func decoderToleratesPartialFutureBrokenShape() throws {
    // A partial future / partial broken daemon (one field present,
    // others missing) should NOT make decoding fail. The CLI's
    // atomic-triple check then degrades the print to bare `ok`
    // rather than turning an accepted gesture into a CLI failure.
    let partial = Data(#"{"ok":true,"dispatched":"tap"}"#.utf8)
    let ack = try JSONDecoder().decode(SwipeAck.self, from: partial)
    #expect(ack.success == true)
    #expect(ack.dispatched == .tap)
    #expect(ack.steps == nil)
    #expect(ack.durationMs == nil)
}
