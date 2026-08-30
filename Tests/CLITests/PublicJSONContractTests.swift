// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
@testable import DeviceTermCLI
import Foundation
import Testing

// Exact encodings for the DeviceTerm-owned payloads documented in
// docs/INTEGRATION.md. Sorted keys make drift visible without making key order
// part of the public contract.

private func contractJSON(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    return try #require(String(data: data, encoding: .utf8))
}

@Test
func panesListEntryJSONContract() throws {
    let pane = PanesListEntry(
        paneId: "PANE",
        udid: "SIM",
        state: .rendering,
        family: "phone",
        shortId: "phn001",
        name: "Primary",
        capabilities: .simulator,
        target: .sim(udid: "SIM"),
        orientationConfirmationSupported: true,
        orientation: .landscapeLeft,
        surface: .init(sequence: 42, width: 1_200, height: 800)
    )
    let expected = #"{"capabilities":{"accessibility":true,"button":true,"#
        + #""crown":true,"key":true,"location":true,"rotate":true,"text":true,"#
        + #""touch":true},"family":"phone","name":"Primary","orientation":"landscapeLeft","#
        + #""orientationConfirmationSupported":true,"#
        + #""paneId":"PANE","#
        + #""shortId":"phn001","state":"rendering","surface":{"height":800,"sequence":42,"#
        + #""width":1200},"target":{"sim":{"udid":"SIM"}},"udid":"SIM"}"#
    let actual = try contractJSON(pane)
    #expect(actual == expected)

    let minimal = PanesListEntry(paneId: "P", udid: "U", state: .failed)
    #expect(try contractJSON(minimal) == #"{"paneId":"P","state":"failed","udid":"U"}"#)
}

@Test
func deviceRosterEntryJSONContract() throws {
    let entry = DeviceRosterEntry(
        id: "DEVICE",
        kind: .device,
        name: "Development iPhone",
        model: "iPhone 17 Pro",
        osVersion: "27.0",
        state: "connected",
        attached: true,
        ownerSessionId: "SESSION"
    )
    let expected = #"{"attached":true,"id":"DEVICE","kind":"device","#
        + #""model":"iPhone 17 Pro","name":"Development iPhone","osVersion":"27.0","#
        + #""ownerSessionId":"SESSION","state":"connected"}"#
    #expect(try contractJSON(entry) == expected)

    let minimal = DeviceRosterEntry(id: "SIM", kind: .sim)
    #expect(try contractJSON(minimal) == #"{"attached":false,"id":"SIM","kind":"sim"}"#)
}

@Test
func tabInfoPayloadJSONContract() throws {
    let payload = TabInfoPayload(
        sessionId: "SESSION",
        shortId: "abc123",
        name: "feature",
        role: "agent",
        cwd: "/tmp/project",
        label: "agent",
        isCurrent: true,
        simPanes: [
            SimPanePayload(
                paneId: "PANE",
                udid: "SIM",
                shortId: "phn001",
                displayName: "iPhone 17 Pro",
                family: "phone"
            )
        ]
    )
    let expected = #"{"cwd":"\/tmp\/project","isCurrent":true,"label":"agent","#
        + #""name":"feature","role":"agent","sessionId":"SESSION","shortId":"abc123","#
        + #""simPanes":[{"displayName":"iPhone 17 Pro","family":"phone","paneId":"PANE","#
        + #""shortId":"phn001","udid":"SIM"}]}"#
    let actual = try contractJSON(payload)
    #expect(actual == expected)

    let minimal = TabInfoPayload(
        sessionId: "SESSION",
        shortId: nil,
        name: nil,
        role: "agent",
        cwd: nil,
        label: nil,
        isCurrent: false,
        simPanes: []
    )
    #expect(
        try contractJSON(minimal)
            == #"{"isCurrent":false,"role":"agent","sessionId":"SESSION","simPanes":[]}"#
    )
}

@Test
func paneInfoPayloadJSONContract() throws {
    let payload = PaneInfoPayload(
        paneId: "PANE",
        udid: "SIM",
        shortId: "phn001",
        name: "Primary",
        displayName: "iPhone 17 Pro",
        family: "phone",
        linkedSessionId: "SESSION"
    )
    let expected = #"{"displayName":"iPhone 17 Pro","family":"phone","#
        + #""linkedSessionId":"SESSION","name":"Primary","paneId":"PANE","#
        + #""shortId":"phn001","udid":"SIM"}"#
    #expect(try contractJSON(payload) == expected)

    let minimal = PaneInfoPayload(
        paneId: "PANE",
        udid: "SIM",
        shortId: nil,
        name: nil,
        displayName: "iPhone 17 Pro",
        family: "phone",
        linkedSessionId: "SESSION"
    )
    let minimalExpected = #"{"displayName":"iPhone 17 Pro","family":"phone","#
        + #""linkedSessionId":"SESSION","paneId":"PANE","udid":"SIM"}"#
    #expect(try contractJSON(minimal) == minimalExpected)
}

@Test
func windowAndCapturePayloadJSONContracts() throws {
    let window = WindowInfoPayload(
        index: 1,
        isKey: true,
        tabCount: 3,
        selectedTabShortId: "abc123"
    )
    #expect(
        try contractJSON(window)
            == #"{"index":1,"isKey":true,"selectedTabShortId":"abc123","tabCount":3}"#
    )

    let windowWithoutSelection = WindowInfoPayload(
        index: 2,
        isKey: false,
        tabCount: 0,
        selectedTabShortId: nil
    )
    #expect(
        try contractJSON(windowWithoutSelection)
            == #"{"index":2,"isKey":false,"tabCount":0}"#
    )

    let capture = TabCapturePayload(text: "line one\nline two")
    #expect(try contractJSON(capture) == #"{"text":"line one\nline two"}"#)
}
