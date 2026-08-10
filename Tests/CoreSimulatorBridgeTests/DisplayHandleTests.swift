// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import Foundation
import IOSurface
import Testing

/// Gate on probe compatibility (same model as LoaderTests). The
/// booted-sim live streaming tests (start/displaySize/stop) live in the
/// deliberate `CoreSimulatorLiveTests` track; this file keeps the
/// hermetic lookup / error-path checks.
private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

// MARK: - Lookup behavior

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func handleForUnknownUDIDThrows() {
    #expect(throws: (any Error).self) {
        _ = try SimDisplayHandle.handle(forUDID: "00000000-0000-0000-0000-000000000000")
    }
}

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func handleForKnownUDIDPreservesUDID() throws {
    let devices = try SimDeviceHandle.allDevices()
    guard let first = devices.first else { return }
    let handle = try SimDisplayHandle.handle(forUDID: first.udid)
    #expect(handle.udid == first.udid)
}

// MARK: - Degraded host

@Test(.disabled(if: coreSimulatorAvailable, "only meaningful on hosts where the probe doesn't pass"))
func handleForUDIDThrowsGracefullyWhenProbeFails() {
    #expect(throws: (any Error).self) {
        _ = try SimDisplayHandle.handle(forUDID: "00000000-0000-0000-0000-000000000000")
    }
}
