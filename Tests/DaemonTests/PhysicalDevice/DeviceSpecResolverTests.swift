// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Testing

// DeviceSpecResolverTests: the conservative spec→deviceId policy that
// backs the shim's contextual auto-attach. `deviceId` is the device's
// real UDID, so an exact-handle match catches a UDID spec directly; the
// resolver still also matches by name and falls back to the sole connected
// device, and refuses to guess when a multi-device host offers no match.

private func device(
    _ id: String,
    name: String? = nil
) -> PhysicalDeviceInfo {
    PhysicalDeviceInfo(deviceId: id, name: name)
}

@Test("sole connected device resolves any spec")
func soleDeviceResolvesAnySpec() {
    let devices = [device("fdab::1")]
    #expect(DeviceSpecResolver.resolve(spec: "00008130-UDID", devices: devices) == "fdab::1")
    #expect(DeviceSpecResolver.resolve(spec: "My iPhone", devices: devices) == "fdab::1")
}

@Test("exact deviceId handle match")
func exactHandleMatch() {
    let devices = [device("fdab::1"), device("fdab::2")]
    #expect(DeviceSpecResolver.resolve(spec: "fdab::2", devices: devices) == "fdab::2")
}

@Test("name match when enumeration carries names")
func nameMatch() {
    let devices = [
        device("fdab::1", name: "Work iPhone"),
        device("fdab::2", name: "Test iPhone")
    ]
    #expect(DeviceSpecResolver.resolve(spec: "Test iPhone", devices: devices) == "fdab::2")
}

@Test("multi-device host with no match refuses to guess")
func multiDeviceNoMatchIsNil() {
    let devices = [device("fdab::1"), device("fdab::2")]
    #expect(DeviceSpecResolver.resolve(spec: "00008130-UDID", devices: devices) == nil)
}

@Test("no connected devices resolves to nil")
func emptyIsNil() {
    #expect(DeviceSpecResolver.resolve(spec: "anything", devices: []) == nil)
}
