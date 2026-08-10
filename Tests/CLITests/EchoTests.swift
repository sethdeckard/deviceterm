// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
@testable import DeviceTermCLI
import Foundation
import Testing

// Echo + ResolvedPane: the receipt-line shape that every
// pane.input.* command emits. The contract:
//
//   ok udid=<UDID> pane=<short_id|paneId> [key=value …]
//
// Tests pin the leading two columns + per-command field ordering
// so agents parsing the line by position (`awk '{print $3}'`) or
// by key (`grep -oE 'pane=[a-z0-9]+'`) both stay valid across
// future tweaks. Pure formatter: no I/O, no env.

// MARK: - ResolvedPane

@Test
func resolvedPanePrefersShortIdForDisplay() {
    let pane = ResolvedPane(paneId: "AAAA-…", udid: "U", shortId: "ab12cd")
    #expect(pane.displayLabel == "ab12cd")
}

@Test
func resolvedPaneFallsBackToPaneIdWhenShortIdMissing() {
    // Pre-identifier-model daemon: PanesListEntry.shortId is nil.
    // The receipt still needs a non-nil pane label, so we fall back
    // to the canonical paneId UUID.
    let pane = ResolvedPane(paneId: "AAAA-1234-…", udid: "U", shortId: nil)
    #expect(pane.displayLabel == "AAAA-1234-…")
}

// MARK: - Echo.ok line shape

@Test
func okEmitsLeadingOkUdidPane() {
    let line = Echo.ok(udid: "DEAD-BEEF", pane: "ab12cd")
    #expect(line == "ok udid=DEAD-BEEF pane=ab12cd")
}

@Test
func okAppendsPerCommandFieldsInOrder() {
    // Field order is documented; downstream parsers can rely on
    // either key match or position. The helper preserves the
    // caller-supplied order.
    let line = Echo.ok(
        udid: "U",
        pane: "P",
        fields: [("delta", "5"), ("durationMs", "200")]
    )
    #expect(line == "ok udid=U pane=P delta=5 durationMs=200")
}

@Test
func okSplitsOnWhitespaceIntoCleanColumns() {
    // awk '{print $3}' should give `pane=<short_id>` on every line.
    let line = Echo.ok(udid: "U", pane: "ab12cd", fields: [("x", "0.5")])
    let columns = line.split(separator: " ").map(String.init)
    #expect(columns[0] == "ok")
    #expect(columns[1] == "udid=U")
    #expect(columns[2] == "pane=ab12cd")
    #expect(columns[3] == "x=0.5")
}

@Test
func okHandlesEmptyFieldsList() {
    let line = Echo.ok(udid: "U", pane: "P")
    // Trailing whitespace would break agents that strip-and-split;
    // the empty-fields path must not emit a trailing space.
    #expect(line == "ok udid=U pane=P")
    #expect(!line.hasSuffix(" "))
}

// MARK: - swipeFields

@Test
func swipeFieldsCarriesFullAckTriple() {
    // SwipeAck's only public init takes (steps, durationMs) and
    // derives `dispatched` from `steps` per the daemon's contract
    // (steps > 1 → drag).
    let ack = SwipeAck(steps: 12, durationMs: 200)
    let fields = Echo.swipeFields(ack)
    let keys = fields.map(\.0)
    #expect(keys == ["dispatched", "steps", "durationMs"])
    let values = fields.map(\.1)
    #expect(values == ["drag", "12", "200"])
}

@Test
func swipeFieldsCarriesTapPromotionMarker() {
    // Sub-frame durations collapse to `steps == 1` →
    // `dispatched=tap`. The receipt has to preserve that signal so
    // an agent can detect the silent promotion.
    let ack = SwipeAck(steps: 1, durationMs: 16)
    let fields = Echo.swipeFields(ack)
    #expect(fields.first?.0 == "dispatched")
    #expect(fields.first?.1 == "tap")
}

@Test
func swipeFieldsEmptyForBareOkAck() throws {
    // Sparkle skew: an older daemon sends `{ok: true}` with no
    // SwipeAck extension fields. The receipt degrades to just
    // udid + pane rather than failing on an accepted gesture.
    // SwipeAck doesn't expose a nil-fields init publicly, so decode
    // the on-wire bare-ack shape instead, which is exactly what
    // the runtime path does.
    let bareWire = Data(#"{"ok":true}"#.utf8)
    let ack = try JSONDecoder().decode(SwipeAck.self, from: bareWire)
    #expect(Echo.swipeFields(ack).isEmpty)
}

// MARK: - End-to-end composed line shape

@Test
func swipeReceiptLineIsTheExpectedRichShape() {
    let resolved = ResolvedPane(paneId: "PID", udid: "DEAD", shortId: "ab12cd")
    let ack = SwipeAck(steps: 8, durationMs: 250)
    let line = Echo.ok(
        udid: resolved.udid,
        pane: resolved.displayLabel,
        fields: Echo.swipeFields(ack)
    )
    #expect(line == "ok udid=DEAD pane=ab12cd dispatched=drag steps=8 durationMs=250")
}

@Test
func tapReceiptLineCarriesCoordsOnly() {
    let resolved = ResolvedPane(paneId: "PID", udid: "U", shortId: "tp1234")
    let line = Echo.ok(
        udid: resolved.udid,
        pane: resolved.displayLabel,
        fields: [("x", "0.5"), ("y", "0.25")]
    )
    #expect(line == "ok udid=U pane=tp1234 x=0.5 y=0.25")
}
