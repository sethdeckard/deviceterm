// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreSimulatorBridge
import Foundation
import Testing

/// Gate on probe compatibility, the same model as the other bridge suites.
/// The booted-sim live tests (tree walks, multi-tenant) live in the
/// deliberate `CoreSimulatorLiveTests` track; this file keeps only the
/// hermetic client-construction / error-path checks that need
/// CoreSimulator loadable but not a booted sim.
private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

// MARK: - Lookup

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func accessibilityClientForUnknownUDIDThrows() {
    #expect(throws: (any Error).self) {
        _ = try SimAccessibility.client(forUDID: "00000000-0000-0000-0000-000000000000")
    }
}

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func accessibilityClientForKnownUDIDPreservesUDID() throws {
    let devices = try SimDeviceHandle.allDevices()
    guard let first = devices.first else { return }
    let client = try SimAccessibility.client(forUDID: first.udid)
    #expect(client.udid == first.udid)
}

// MARK: - Degraded host

@Test(.disabled(if: coreSimulatorAvailable, "only meaningful on hosts where the probe doesn't pass"))
func accessibilityClientThrowsGracefullyWhenProbeFails() {
    #expect(throws: (any Error).self) {
        _ = try SimAccessibility.client(forUDID: "00000000-0000-0000-0000-000000000000")
    }
}
