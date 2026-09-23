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

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func handleReportsNoBoundPanelBeforeStart() throws {
    // Panel identity stays at its unknown values, 0 and nil, until `start`
    // resolves a renderable.
    let devices = try SimDeviceHandle.allDevices()
    guard let first = devices.first else { return }
    let handle = try SimDisplayHandle.handle(forUDID: first.udid)
    #expect(handle.boundScreenID == 0)
    #expect(handle.boundScreenUniqueId == nil)
}

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func handleReportsOnePanelBeforeStart() throws {
    // The panel count comes from resolving the renderable, so an unstarted
    // handle claims no second panel and its consumer skips the fold-following
    // work entirely.
    let devices = try SimDeviceHandle.allDevices()
    guard let first = devices.first else { return }
    let handle = try SimDisplayHandle.handle(forUDID: first.udid)
    #expect(!handle.hasMultiplePanels)
}

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func rebindingBeforeStartReportsNoChange() throws {
    // Nothing is bound yet, so there is no panel to move off. Refusing here is
    // what lets a caller poll without checking the handle's state first.
    let devices = try SimDeviceHandle.allDevices()
    guard let first = devices.first else { return }
    let handle = try SimDisplayHandle.handle(forUDID: first.udid)
    #expect(!handle.rebindToLitPanel())
}

// MARK: - Degraded host

@Test(.disabled(if: coreSimulatorAvailable, "only meaningful on hosts where the probe doesn't pass"))
func handleForUDIDThrowsGracefullyWhenProbeFails() {
    #expect(throws: (any Error).self) {
        _ = try SimDisplayHandle.handle(forUDID: "00000000-0000-0000-0000-000000000000")
    }
}
