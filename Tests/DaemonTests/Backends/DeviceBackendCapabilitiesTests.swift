// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Testing

/// The simulator capability set varies by family in one flag: only a watch
/// gets `crown`, since a crown event sent to any other family breaks the
/// next HID client built in the process.
@Test("simulator capabilities by family", arguments: DeviceFamily.allCases)
func aSimulatorAdvertisesCrownForAWatchFamilyOnly(family: DeviceFamily) {
    let capabilities = DeviceBackendCapabilities.simulator(family: family)
    #expect(capabilities.crown == (family == .watch))
    #expect(capabilities.touch && capabilities.key && capabilities.text && capabilities.button)
    #expect(capabilities.rotate && capabilities.accessibility && capabilities.location)
    #expect(!capabilities.fold)
}
