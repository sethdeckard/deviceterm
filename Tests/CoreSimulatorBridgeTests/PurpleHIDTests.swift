// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import Foundation
import Testing

/// Gate on probe compatibility (same model as the other bridge suites).
/// The booted-sim live rotation test lives in the deliberate
/// `CoreSimulatorLiveTests` track; this file keeps the hermetic enum +
/// client-construction / error-path checks.
private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

// MARK: - Orientation enum

@Test
func orientationRawValuesMatchUIDeviceOrientation() {
    // The integer values MUST match UIKit's UIDeviceOrientation so the
    // simulator's layout engine reads them directly without a remap.
    // Apple's documented values: portrait=1, portraitUpsideDown=2,
    // landscapeLeft=3 (home button on right), landscapeRight=4 (home
    // button on left). Inverting any of these makes
    // `client.rotate(to:)` produce the wrong physical orientation.
    #expect(CSBDeviceOrientation.portrait.rawValue == 1)
    #expect(CSBDeviceOrientation.portraitUpsideDown.rawValue == 2)
    #expect(CSBDeviceOrientation.landscapeLeft.rawValue == 3)
    #expect(CSBDeviceOrientation.landscapeRight.rawValue == 4)
}

// MARK: - Lookup

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func purpleClientForUnknownUDIDThrows() {
    #expect(throws: (any Error).self) {
        _ = try SimPurpleHID.client(forUDID: "00000000-0000-0000-0000-000000000000")
    }
}

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func purpleClientForKnownUDIDPreservesUDID() throws {
    let devices = try SimDeviceHandle.allDevices()
    guard let first = devices.first else { return }
    let client = try SimPurpleHID.client(forUDID: first.udid)
    #expect(client.udid == first.udid)
}

// MARK: - Degraded host

@Test(.disabled(if: coreSimulatorAvailable, "only meaningful on hosts where the probe doesn't pass"))
func purpleClientForUDIDThrowsGracefullyWhenProbeFails() {
    #expect(throws: (any Error).self) {
        _ = try SimPurpleHID.client(forUDID: "00000000-0000-0000-0000-000000000000")
    }
}
