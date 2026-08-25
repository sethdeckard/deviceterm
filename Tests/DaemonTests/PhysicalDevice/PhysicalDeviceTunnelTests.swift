// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Testing

// PhysicalDeviceCoordinator enumeration: the cheap usbmux roster projection
// used by the picker and `devices.list`. Driven against a stubbed `devicectl`
// so it runs without a real device. (`DeviceRouteResolver` polling is covered
// directly by `DeviceReachabilityTests`.)

@Test("enumerate projects the devicectl roster to UDID-keyed entries")
func enumerateProjectsRoster() async {
    let coordinator = PhysicalDeviceCoordinator(
        listDevices: {
            [
                DeviceCtlDevice(
                    udid: "00000000-1111",
                    name: "Test iPhone",
                    model: "iPhone 16 Pro",
                    osVersion: "27.0",
                    transportType: "wired",
                    tunnelState: "disconnected",
                    tunnelIPAddress: nil
                )
            ]
        }
    )
    let devices = await coordinator.enumerate()
    #expect(devices.count == 1)
    #expect(devices[0].deviceId == "00000000-1111")
    #expect(devices[0].name == "Test iPhone")
    #expect(devices[0].model == "iPhone 16 Pro")
}
