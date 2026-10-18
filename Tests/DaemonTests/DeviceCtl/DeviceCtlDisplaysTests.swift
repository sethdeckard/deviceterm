// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

// DeviceCtlDisplaysTests: the argv `devicectl device info displays` is given,
// and how its payload becomes the lit panel. The fixture is a capture from an
// iPhone Duo Simulator with its inner panel (display 3) lit and the cover
// (display 1) dark; the fake runner avoids subprocesses.

private func loadFixture() throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: "devicectl-displays", withExtension: "json")
    )
    return try Data(contentsOf: url)
}

/// `devicectl`'s payload with each display's `active` flag set as given.
private func payload(_ displays: [(id: UInt32, active: Bool)]) -> Data {
    let entries = displays.map { #"{"displayId": \#($0.id), "active": \#($0.active)}"# }
    return Data(#"{"result": {"displays": [\#(entries.joined(separator: ","))]}}"#.utf8)
}

@Test
func readsTheLitPanelFromACapture() throws {
    #expect(DeviceCtlDisplays.activePanel(fromJSON: try loadFixture()) == .panel(3))
}

@Test("a payload with no single active panel is undecided", arguments: [
    [(UInt32(1), false), (3, false)],
    [(1, true), (3, true)]
])
func noSingleActivePanelIsUndecided(displays: [(UInt32, Bool)]) {
    let data = payload(displays.map { (id: $0.0, active: $0.1) })
    #expect(DeviceCtlDisplays.activePanel(fromJSON: data) == .undecided)
}

@Test
func anUnreadablePayloadIsUnavailable() {
    #expect(DeviceCtlDisplays.activePanel(fromJSON: Data("not json".utf8)) == .unavailable)
    #expect(DeviceCtlDisplays.activePanel(fromJSON: Data(#"{"result": {}}"#.utf8)) == .unavailable)
}

@Test
func asksForTheDisplaysQuietlyIntoAFile() {
    #expect(
        DeviceCtlDisplays.arguments(deviceId: "UDID", jsonPath: "/tmp/x.json")
            == [
                "devicectl", "device", "info", "displays", "--device", "UDID",
                "--json-output", "/tmp/x.json", "--quiet"
            ]
    )
}

@Test
func aRunThatFailsOrWritesNothingIsUnavailable() throws {
    let failed = DeviceCtlDisplays { _, _ in DeviceCtlRun(status: 1, json: try? loadFixture(), stderr: "no") }
    #expect(failed.activePanel(deviceId: "UDID") == .unavailable)
    let empty = DeviceCtlDisplays { _, _ in DeviceCtlRun(status: 0, json: nil, stderr: "") }
    #expect(empty.activePanel(deviceId: "UDID") == .unavailable)
    let fixture = try loadFixture()
    let working = DeviceCtlDisplays { _, _ in DeviceCtlRun(status: 0, json: fixture, stderr: "") }
    #expect(working.activePanel(deviceId: "UDID") == .panel(3))
}
