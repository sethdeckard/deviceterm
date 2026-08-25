// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Testing

// DeviceFamily is decoded leniently from the wire string so a newer
// daemon that sends a family this client doesn't know maps to .unknown
// instead of failing, since Apple adds families independent of our wireVersion.

@Test
func deviceFamilyWireDecodeIsLenient() {
    #expect(DeviceFamily(wire: "watch") == .watch)
    #expect(DeviceFamily(wire: "phone") == .phone)
    #expect(DeviceFamily(wire: "pad") == .pad)
    #expect(DeviceFamily(wire: "tv") == .tv)
    #expect(DeviceFamily(wire: "vision") == .unknown)  // a future family
    #expect(DeviceFamily(wire: "") == .unknown)
}

@Test
func deviceFamilyRawValues() {
    #expect(
        DeviceFamily.allCases.map(\.rawValue)
        == ["watch", "phone", "pad", "tv", "unknown"]
        )
}
