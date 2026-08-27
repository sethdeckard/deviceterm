// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreSimulatorBridge
import Foundation
import Testing

/// Gate on probe compatibility, the same model as the other bridge suites.
/// The booted-sim live send tests (tap/pinch/keyboard/buttons) live in
/// the deliberate `CoreSimulatorLiveTests` track; this file keeps only
/// the hermetic client-construction / error-path checks.
private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

// MARK: - Lookup

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func clientForUnknownUDIDThrows() {
    #expect(throws: (any Error).self) {
        _ = try SimHIDClient.client(forUDID: "00000000-0000-0000-0000-000000000000")
    }
}

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func clientForKnownUDIDPreservesUDID() throws {
    let devices = try SimDeviceHandle.allDevices()
    guard let first = devices.first else { return }
    let client = try SimHIDClient.client(forUDID: first.udid)
    #expect(client.udid == first.udid)
}

// MARK: - Edge-tagged builder

/// The compatibility probe only resolves `IndigoHIDMessageForMouseNSEvent`
/// by name. This test invokes the builder for every event type the App
/// Switcher path emits and verifies that the edge tag changes the payload.
@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func edgeTaggedMessageBuildsForEveryPhaseThePathSends() throws {
    try SimHIDClient.isEdgeTouchBuildable()
}

// MARK: - Degraded host

@Test(.disabled(if: coreSimulatorAvailable, "only meaningful on hosts where the probe doesn't pass"))
func clientForUDIDThrowsGracefullyWhenProbeFails() {
    #expect(throws: (any Error).self) {
        _ = try SimHIDClient.client(forUDID: "00000000-0000-0000-0000-000000000000")
    }
}
