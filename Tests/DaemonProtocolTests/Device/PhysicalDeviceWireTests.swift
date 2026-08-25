// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

// Wire shapes + method names for the physical-device surface.

@Test
func deviceKindRawValues() {
    #expect(DeviceKind.sim.rawValue == "sim")
    #expect(DeviceKind.device.rawValue == "device")
}

@Test
func physicalDeviceMethodRawValues() {
    #expect(RPCMethod.physicalDeviceList.rawValue == "physicalDevice.list")
    #expect(RPCMethod.physicalDeviceAttach.rawValue == "physicalDevice.attach")
    #expect(RPCMethod.devicesList.rawValue == "devices.list")
}

@Test
func physicalDeviceListEntryRoundTrips() throws {
    let entry = PhysicalDeviceListEntry(
        deviceId: "00008130-001C195E0E91802E",
        name: "Jane's iPhone",
        model: "iPhone17,1",
        osVersion: "17.5",
        available: false,
        unavailableReason: "iOS too old"
    )
    let data = try JSONEncoder().encode(entry)
    let restored = try JSONDecoder().decode(PhysicalDeviceListEntry.self, from: data)
    #expect(restored == entry)
    #expect(restored.osVersion == "17.5")
}

@Test
func physicalDeviceListEntryDefaultsAvailable() {
    let entry = PhysicalDeviceListEntry(deviceId: "00008130-001C195E0E91802E")
    #expect(entry.available)
    #expect(entry.name == nil)
    #expect(entry.osVersion == nil)
    #expect(entry.unavailableReason == nil)
}

@Test
func deviceRosterEntryRoundTrips() throws {
    for entry in [
        DeviceRosterEntry(
            id: "ABC",
            kind: .sim,
            name: "iPhone 17",
            state: "Booted",
            attached: true,
            ownerSessionId: "S1"
        ),
        DeviceRosterEntry(
            id: "00008130-001C195E0E91802E",
            kind: .device,
            name: nil,
            state: "connected"
        )
    ] {
        let data = try JSONEncoder().encode(entry)
        let restored = try JSONDecoder().decode(DeviceRosterEntry.self, from: data)
        #expect(restored == entry)
    }
}

@Test
func deviceRosterEntryEncodesKindAsString() throws {
    let data = try JSONEncoder().encode(DeviceRosterEntry(id: "x", kind: .device))
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["kind"] as? String == "device")
}
