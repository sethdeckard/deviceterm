// SPDX-License-Identifier: GPL-3.0-or-later

@testable import DeviceTermCLI
import Foundation
import Testing

// Receipt JSON shapes. Tests pin the byte output of each
// per-command struct so downstream consumers (jq pipelines, agent
// orchestrators) can rely on a stable shape. Encoding uses
// `JSONEncoder.OutputFormatting.sortedKeys` so keys appear in
// alphabetical order; tests assert against that ordering.

// MARK: - Encoding helper

private func encode<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    return try #require(String(data: data, encoding: .utf8))
}

// MARK: - Tap

@Test
func tapReceiptJSONShape() throws {
    let receipt = Receipt.Tap(
        udid: "DEAD",
        paneId: "PID",
        shortId: "ab12cd",
        x: 0.5,
        y: 0.25
    )
    let json = try encode(receipt)
    #expect(json == #"{"ok":true,"paneId":"PID","shortId":"ab12cd","udid":"DEAD","x":0.5,"y":0.25}"#)
}

@Test
func tapReceiptOmitsNilShortId() throws {
    // Synthesized Encodable uses encodeIfPresent for Optionals, so
    // nil shortId (from an older daemon that predates the field)
    // omits the key entirely rather than emitting `null`. Consumers
    // detect skew via jq `has(\"shortId\")`. The current daemon
    // always emits it.
    let receipt = Receipt.Tap(
        udid: "U",
        paneId: "P",
        shortId: nil,
        x: 0,
        y: 0
    )
    let json = try encode(receipt)
    #expect(!json.contains("shortId"))
    // All non-nil keys still present.
    #expect(json.contains(#""udid":"U""#))
    #expect(json.contains(#""paneId":"P""#))
}

// MARK: - Swipe

@Test
func swipeReceiptJSONShapeFullAck() throws {
    let receipt = Receipt.Swipe(
        udid: "DEAD",
        paneId: "PID",
        shortId: "ab12cd",
        dispatched: "drag",
        steps: 8,
        durationMs: 250
    )
    let json = try encode(receipt)
    let expected = #"{"dispatched":"drag","durationMs":250,"ok":true,"#
        + #""paneId":"PID","shortId":"ab12cd","steps":8,"udid":"DEAD"}"#
    #expect(json == expected)
}

@Test
func swipeReceiptJSONShapeBareAck() throws {
    // Sparkle skew: daemon returned `{"ok":true}` without the
    // SwipeAck extension fields. Synthesized encodeIfPresent
    // omits the three nil keys; the rest of the receipt is
    // intact. Consumers detect skew via `has("dispatched")`.
    let receipt = Receipt.Swipe(
        udid: "U",
        paneId: "P",
        shortId: "ab12cd",
        dispatched: nil,
        steps: nil,
        durationMs: nil
    )
    let json = try encode(receipt)
    #expect(!json.contains("dispatched"))
    #expect(!json.contains("steps"))
    #expect(!json.contains("durationMs"))
    // udid + paneId + shortId still anchor the receipt.
    #expect(json.contains(#""udid":"U""#))
    #expect(json.contains(#""shortId":"ab12cd""#))
}

// MARK: - LongPress

@Test
func longPressReceiptJSONShape() throws {
    let receipt = Receipt.LongPress(
        udid: "U",
        paneId: "P",
        shortId: "lp1234",
        x: 0.4,
        y: 0.6,
        durationMs: 800
    )
    let json = try encode(receipt)
    #expect(json == #"{"durationMs":800,"ok":true,"paneId":"P","shortId":"lp1234","udid":"U","x":0.4,"y":0.6}"#)

    let withoutDuration = Receipt.LongPress(
        udid: "U",
        paneId: "P",
        shortId: "lp1234",
        x: 0.4,
        y: 0.6,
        durationMs: nil
    )
    #expect(
        try encode(withoutDuration)
            == #"{"ok":true,"paneId":"P","shortId":"lp1234","udid":"U","x":0.4,"y":0.6}"#
    )
}

// MARK: - Pinch

@Test
func pinchReceiptOmitsCoordsAndKeepsDuration() throws {
    let receipt = Receipt.Pinch(
        udid: "U",
        paneId: "P",
        shortId: "pn1234",
        durationMs: 300
    )
    let json = try encode(receipt)
    // The receipt deliberately does NOT echo the eight pinch
    // coords, since the line would be unreadable. The JSON mirrors that.
    #expect(json == #"{"durationMs":300,"ok":true,"paneId":"P","shortId":"pn1234","udid":"U"}"#)

    let withoutDuration = Receipt.Pinch(
        udid: "U",
        paneId: "P",
        shortId: "pn1234",
        durationMs: nil
    )
    #expect(
        try encode(withoutDuration)
            == #"{"ok":true,"paneId":"P","shortId":"pn1234","udid":"U"}"#
    )
}

// MARK: - Button

@Test
func buttonReceiptJSONShape() throws {
    let receipt = Receipt.Button(
        udid: "U",
        paneId: "P",
        shortId: "bt1234",
        button: "home"
    )
    let json = try encode(receipt)
    #expect(json == #"{"button":"home","ok":true,"paneId":"P","shortId":"bt1234","udid":"U"}"#)
}

// MARK: - Key

@Test
func keyReceiptEncodesHexKeyCodeString() throws {
    // The keyCode column mirrors the parser's hex-accept and the
    // human-echo's hex output: the JSON value is the same `0x30`
    // form so an agent reading the JSON can paste it straight back
    // into a `deviceterm key` invocation.
    let receipt = Receipt.Key(
        udid: "U",
        paneId: "P",
        shortId: "ky1234",
        keyCode: "0x30",
        down: true
    )
    let json = try encode(receipt)
    #expect(json == #"{"down":true,"keyCode":"0x30","ok":true,"paneId":"P","shortId":"ky1234","udid":"U"}"#)
}

// MARK: - Text

@Test
func textReceiptEmitsBytesNotContent() throws {
    let receipt = Receipt.Text(
        udid: "U",
        paneId: "P",
        shortId: "tx1234",
        bytes: 11
    )
    let json = try encode(receipt)
    #expect(json == #"{"bytes":11,"ok":true,"paneId":"P","shortId":"tx1234","udid":"U"}"#)
    // Defense-in-depth: the typed string must NOT appear in the
    // receipt under any reasonable serialization. The text is of
    // course delivered to the device; the guarantee is only that
    // it isn't echoed back in the receipt, which callers pipe to
    // logs and jq.
    #expect(!json.contains("hello world"))
}

// MARK: - Rotate

@Test
func rotateReceiptJSONShape() throws {
    let receipt = Receipt.Rotate(
        udid: "U",
        paneId: "P",
        shortId: "rt1234",
        orientation: "landscapeLeft",
        direction: nil
    )
    let json = try encode(receipt)
    #expect(json == #"{"ok":true,"orientation":"landscapeLeft","paneId":"P","shortId":"rt1234","udid":"U"}"#)
}

@Test
func relativeRotateReceiptReportsTheDirection() throws {
    // A relative rotate resolves against an orientation only the daemon
    // holds, so the receipt echoes the direction and omits `orientation`
    // rather than reporting a landing spot it would have to guess at.
    let receipt = Receipt.Rotate(
        udid: "U",
        paneId: "P",
        shortId: "rt1234",
        orientation: nil,
        direction: "left"
    )
    let json = try encode(receipt)
    #expect(json == #"{"direction":"left","ok":true,"paneId":"P","shortId":"rt1234","udid":"U"}"#)
}

// MARK: - Crown

@Test
func crownReceiptOmitsNilOptionals() throws {
    // Default crown (no --velocity / --duration) → both keys
    // omitted; only delta is present alongside the udid/pane
    // anchors.
    let receipt = Receipt.Crown(
        udid: "U",
        paneId: "P",
        shortId: "cr1234",
        delta: 5,
        velocity: nil,
        durationMs: nil
    )
    let json = try encode(receipt)
    let expected = #"{"delta":5,"ok":true,"paneId":"P","#
        + #""shortId":"cr1234","udid":"U"}"#
    #expect(json == expected)
}

@Test
func crownReceiptIncludesAllOptionalsWhenSet() throws {
    let receipt = Receipt.Crown(
        udid: "U",
        paneId: "P",
        shortId: "cr1234",
        delta: 30,
        velocity: 2.5,
        durationMs: 1_500
    )
    let json = try encode(receipt)
    #expect(json.contains(#""delta":30"#))
    #expect(json.contains(#""velocity":2.5"#))
    #expect(json.contains(#""durationMs":1500"#))
}

// MARK: - TabsListRow

@Test
func tabsListRowEncodesCurrentMarker() throws {
    let row = Receipt.TabsListRow(
        current: true,
        shortId: "ab12cd",
        name: "alpha",
        displayTitle: "vim foo.swift",
        sessionId: "11111111-1111-1111-1111-111111111111",
        label: "Alpha"
    )
    let json = try encode(row)
    let expected = #"{"current":true,"displayTitle":"vim foo.swift","label":"Alpha","#
        + #""name":"alpha","sessionId":"11111111-1111-1111-1111-111111111111","#
        + #""shortId":"ab12cd","tabId":"11111111-1111-1111-1111-111111111111"}"#
    #expect(json == expected)
}

@Test
func tabsListRowMarksNonCurrentFalse() throws {
    // Non-current row with nil name + label: the `current` bool
    // and `sessionId` always anchor the row; nil name/label are
    // omitted entirely (jq `has("name")` is the absence check).
    let row = Receipt.TabsListRow(
        current: false,
        shortId: "ef34gh",
        name: nil,
        displayTitle: nil,
        sessionId: "22222222-2222-2222-2222-222222222222",
        label: nil
    )
    let json = try encode(row)
    #expect(json.contains(#""current":false"#))
    #expect(!json.contains("name"))
    #expect(!json.contains("label"))
    #expect(!json.contains("displayTitle"))
    #expect(json.contains(#""shortId":"ef34gh""#))
    #expect(json.contains(#""tabId":"22222222-2222-2222-2222-222222222222""#))
}

// MARK: - Workspace receipts

@Test
func tabOpenReceiptJSONShape() throws {
    #expect(
        try encode(Receipt.TabOpen(window: "current"))
            == #"{"ok":true,"window":"current"}"#
    )
}

@Test
func tabCloseReceiptJSONShape() throws {
    #expect(
        try encode(Receipt.TabClose(tab: "abc123", mode: "shutdown"))
            == #"{"mode":"shutdown","ok":true,"tab":"abc123"}"#
    )
}

@Test
func tabRenameReceiptJSONShapeAndOptionalOmission() throws {
    #expect(
        try encode(Receipt.TabRename(tab: "abc123", name: "build"))
            == #"{"name":"build","ok":true,"tab":"abc123"}"#
    )
    #expect(
        try encode(Receipt.TabRename(tab: "abc123", name: nil))
            == #"{"ok":true,"tab":"abc123"}"#
    )
}

@Test
func tabSelectReceiptJSONShape() throws {
    #expect(
        try encode(Receipt.TabSelect(tab: "abc123"))
            == #"{"ok":true,"tab":"abc123"}"#
    )
}

@Test
func tabMoveReceiptJSONShapeAndOptionalOmission() throws {
    #expect(
        try encode(Receipt.TabMove(tab: "abc123", toIndex: 1, toWindow: "2"))
            == #"{"ok":true,"tab":"abc123","toIndex":1,"toWindow":"2"}"#
    )
    #expect(
        try encode(Receipt.TabMove(tab: "abc123", toIndex: nil, toWindow: "2"))
            == #"{"ok":true,"tab":"abc123","toWindow":"2"}"#
    )
    #expect(
        try encode(Receipt.TabMove(tab: "abc123", toIndex: 1, toWindow: nil))
            == #"{"ok":true,"tab":"abc123","toIndex":1}"#
    )
}

@Test
func paneOpenTerminalReceiptJSONShape() throws {
    #expect(
        try encode(Receipt.PaneOpenTerminal(tab: "current"))
            == #"{"ok":true,"tab":"current"}"#
    )
}

@Test
func paneCloseReceiptJSONShape() throws {
    #expect(
        try encode(Receipt.PaneClose(pane: "phn001", mode: "detach"))
            == #"{"mode":"detach","ok":true,"pane":"phn001"}"#
    )
}

@Test
func deviceAttachReceiptJSONShape() throws {
    #expect(
        try encode(Receipt.DeviceAttach(target: "DEVICE", kind: "device"))
            == #"{"kind":"device","ok":true,"target":"DEVICE"}"#
    )
}

@Test
func windowReceiptsPinEverySuccessShape() throws {
    #expect(try encode(Receipt.WindowOpen()) == #"{"ok":true}"#)
    #expect(
        try encode(Receipt.WindowClose(window: "2", mode: "shutdown"))
            == #"{"mode":"shutdown","ok":true,"window":"2"}"#
    )
    #expect(
        try encode(Receipt.WindowFocus(window: "2"))
            == #"{"ok":true,"window":"2"}"#
    )
}

@Test
func tabSendInputReceiptJSONShapeAndOptionalOmission() throws {
    #expect(
        try encode(Receipt.TabSendInput(tab: "abc123", bytes: 10, typeDelayMillis: 40))
            == #"{"bytes":10,"ok":true,"tab":"abc123","typeDelayMillis":40}"#
    )
    #expect(
        try encode(Receipt.TabSendInput(tab: "abc123", bytes: 10))
            == #"{"bytes":10,"ok":true,"tab":"abc123"}"#
    )
}

@Test
func tabSetProtectedReceiptJSONShape() throws {
    #expect(
        try encode(Receipt.TabSetProtected(tab: "current", isProtected: true, committed: false))
            == #"{"committed":false,"isProtected":true,"ok":true,"tab":"current"}"#
    )
}
