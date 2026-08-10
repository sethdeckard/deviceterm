// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import Foundation
import Testing

// MARK: - Pure: state-enum mapping
//
// The enum mirrors CoreSimulator's raw values 1:1 and these tests pin
// that contract. A wrong table is easy to miss: most code only ever
// checks Booted, so a mapping that disagrees on every other state can
// still happen to agree on that one and look correct in practice.

@Test
func stateEnumRawValuesMatchCoreSimulator() {
    // Empirically confirmed values on macOS 26.4 / Xcode 26.4, aligned
    // with FBSimulatorControl's FBSimulatorState.
    #expect(CSBSimState.creating.rawValue == 0)
    #expect(CSBSimState.shutdown.rawValue == 1)
    #expect(CSBSimState.booting.rawValue == 2)
    #expect(CSBSimState.booted.rawValue == 3)
    #expect(CSBSimState.shuttingDown.rawValue == 4)
}

@Test
func stateEnumUnknownIsDistinctSentinel() {
    // The Unknown sentinel must not collide with any real raw value, so
    // future drift can never silently map onto a documented state.
    let real: [CSBSimState] = [.creating, .shutdown, .booting, .booted, .shuttingDown]
    #expect(!real.contains(.unknown))
    #expect(CSBSimState.unknown.rawValue < 0)
}

// MARK: - Integration: live device-set enumeration
//
// Gated on probe().ok per the same logic as LoaderTests, so degraded hosts
// skip rather than fail.

private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func liveAllDevicesReturnsNonEmptyArray() throws {
    let devices = try SimDeviceHandle.allDevices()
    #expect(!devices.isEmpty, "developer host should have at least one simulator profile")
}

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func liveAllDevicesHaveUDIDAndName() throws {
    let devices = try SimDeviceHandle.allDevices()
    for info in devices {
        #expect(!info.udid.isEmpty, "every device must have a UDID")
        #expect(!info.name.isEmpty, "every device must have a name")
        // Runtime / deviceType identifiers can be empty on some unavailable
        // runtimes; don't assert on those.
    }
}

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func liveAllDevicesNormalizeStateToKnownValues() throws {
    let devices = try SimDeviceHandle.allDevices()
    let allowed: Set<CSBSimState> = [
        .creating,
        .shutdown,
        .booting,
        .booted,
        .shuttingDown
    ]
    for info in devices {
        #expect(
            allowed.contains(info.state),
                "unexpected state for \(info.name): \(info.state.rawValue)"
            )
    }
}

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func liveHandleForUDIDRoundTrips() throws {
    let devices = try SimDeviceHandle.allDevices()
    guard let first = devices.first else {
        Issue.record("host has no devices to round-trip")
        return
    }
    let handle = try SimDeviceHandle.handle(forUDID: first.udid)
    #expect(handle.udid.lowercased() == first.udid.lowercased())
    #expect(handle.name == first.name)
    // state may have changed since the snapshot; just confirm it's a
    // valid value.
    #expect(handle.state != .unknown)
}

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func liveHandleForUDIDIsCaseInsensitive() throws {
    let devices = try SimDeviceHandle.allDevices()
    guard let first = devices.first else { return }
    let upper = try SimDeviceHandle.handle(forUDID: first.udid.uppercased())
    let lower = try SimDeviceHandle.handle(forUDID: first.udid.lowercased())
    #expect(upper.udid.lowercased() == lower.udid.lowercased())
}

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func liveHandleForUnknownUDIDThrows() {
    let bogusUDID = "00000000-0000-0000-0000-000000000000"
    #expect(throws: (any Error).self) {
        _ = try SimDeviceHandle.handle(forUDID: bogusUDID)
    }
}

// On a degraded host, confirm the bridge surfaces the failure as a
// throwing error instead of crashing. This is the contract the live
// tests above rely on for graceful skipping.
@Test(.disabled(if: coreSimulatorAvailable, "only meaningful on hosts where the probe doesn't pass"))
func allDevicesThrowsGracefullyWhenProbeFails() {
    #expect(throws: (any Error).self) {
        _ = try SimDeviceHandle.allDevices()
    }
}
