// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Testing

// Pure classification of CoreSimulator device-type identifiers into the
// coarse `family` the wire carries. The daemon owns this so clients never
// parse identifiers themselves.

@Test(
    "device family classification",
    arguments: [
    ("com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm", DeviceFamily.watch),
    ("com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Ultra-3-49mm", DeviceFamily.watch),
    ("com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", DeviceFamily.phone),
    ("com.apple.CoreSimulator.SimDeviceType.iPod-touch--7th-generation-", DeviceFamily.phone),
    ("com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB", DeviceFamily.pad),
    ("com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K", DeviceFamily.tv),
    ("com.apple.CoreSimulator.SimDeviceType.Some-Future-Device", DeviceFamily.unknown),
    ("", DeviceFamily.unknown)
    ]
    )
func classifiesDeviceFamily(input: String, expected: DeviceFamily) {
    #expect(DeviceFamilyClassifier.classify(input) == expected)
}
