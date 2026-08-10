// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import Foundation
import Testing

// Live rotation against a booted sim (the PurpleWorkspacePort Mach
// service only exists on a booted device). Deliberate `make test-live`
// track. The orientation-enum value test is hermetic and stays in
// CoreSimulatorBridgeTests.
private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

@Test
func rotateThroughEveryOrientationSucceeds() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let client = try SimPurpleHID.client(forUDID: booted.udid)
    // End on portrait so we leave the host's sim in a sane state.
    for orientation in [
        CSBDeviceOrientation.landscapeRight,
        .landscapeLeft,
        .portraitUpsideDown,
        .portrait
    ] {
        try client.rotate(to: orientation)
    }
}
