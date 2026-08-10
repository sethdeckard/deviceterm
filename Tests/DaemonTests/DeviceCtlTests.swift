// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

// DeviceCtlTests: the pure `devicectl list devices --json` parser that
// feeds the physical-device roster. Decoded against a captured-shape
// fixture (synthetic UDIDs) so the field mapping + the physical/simulated
// filter are pinned without a real device.

private func loadFixture() throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: "devicectl-list-devices", withExtension: "json")
    )
    return try Data(contentsOf: url)
}

@Test("parse keeps physical devices and drops simulators")
func parseFiltersToPhysical() throws {
    let devices = try DeviceCtl.parse(loadFixture())
    #expect(devices.count == 2)
    #expect(devices.allSatisfy { !$0.udid.contains("SIMULATED") })
}

@Test("parse maps identity, name, and model fields")
func parseMapsFields() throws {
    let devices = try DeviceCtl.parse(loadFixture())
    let connected = try #require(devices.first { $0.name == "Test iPhone" })
    #expect(connected.udid == "00000000-1111-2222-3333-444455556666")
    #expect(connected.model == "iPhone 16 Pro")
    #expect(connected.osVersion == "27.0")
    #expect(connected.transportType == "wired")
}

@Test("parse surfaces tunnel address only when connected")
func parseTunnelAddress() throws {
    let devices = try DeviceCtl.parse(loadFixture())
    let connected = try #require(devices.first { $0.tunnelState == "connected" })
    #expect(connected.tunnelIPAddress == "fdaa:bbbb:cccc::1")
    let disconnected = try #require(devices.first { $0.name == "Old iPhone" })
    #expect(disconnected.tunnelState == "disconnected")
    #expect(disconnected.tunnelIPAddress == nil)
}

@Test("parse throws on structurally-invalid payload")
func parseRejectsGarbage() {
    #expect(throws: (any Error).self) {
        _ = try DeviceCtl.parse(Data("not devicectl json".utf8))
    }
}
