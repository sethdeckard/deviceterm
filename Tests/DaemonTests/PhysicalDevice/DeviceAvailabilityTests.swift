// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Testing

// DeviceAvailabilityTests: the pure mirror-capability gate that backs the
// picker's `available`/`unavailableReason`. The live catalog+media probe
// maps its result into a `Probe`; this pins how each maps to a verdict.

@Test("locked / unreachable device is inconclusive → available")
func catalogUnreachableIsAvailable() {
    let verdict = DeviceAvailability.decide(.catalogUnreachable)
    #expect(verdict.available)
    #expect(verdict.reason == nil)
}

@Test("no displayservice (iOS too old) → unavailable with reason")
func missingDisplayServiceIsUnavailable() {
    let verdict = DeviceAvailability.decide(.missingDisplayService)
    #expect(!verdict.available)
    #expect(verdict.reason == DeviceAvailability.unsupportedReason)
}

@Test("non-zero media features → available")
func nonZeroFeaturesIsAvailable() {
    let verdict = DeviceAvailability.decide(.mediaInfo(supportedFeatures: 0x1))
    #expect(verdict.available)
    #expect(verdict.reason == nil)
}

@Test("zero media features → unavailable with reason")
func zeroFeaturesIsUnavailable() {
    let verdict = DeviceAvailability.decide(.mediaInfo(supportedFeatures: 0))
    #expect(!verdict.available)
    #expect(verdict.reason == DeviceAvailability.unsupportedReason)
}

@Test("attaching an iOS-too-old device surfaces the unsupported reason")
func tooOldToMirrorMapsToUnsupportedReason() {
    let error = PhysicalDeviceMethods.mapPhysicalDeviceError(.tooOldToMirror(deviceId: "fd00::1"))
    #expect(error.code == RPCMethodError.invalidParamsCode)
    #expect(error.message == DeviceAvailability.unsupportedReason)
}
