// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreSimulatorBridge
import Foundation
import Testing

// Live HID send paths against a booted sim's digitizer. Deliberate
// `make test-live` track (see AccessibilityLiveTests for the rationale).
// Each send reaches SimulatorKit; we can't observe the touch landing, so
// these assert only that the send didn't throw.
private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

@Test
func tapDownThenTapUpSucceeds() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let client = try SimHIDClient.client(forUDID: booted.udid)
    let center = CGPoint(x: 0.5, y: 0.5)
    try client.tapDown(at: center)
    try client.tapUp(at: center)
}

@Test
func twoFingerPinchSequenceSucceeds() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let client = try SimHIDClient.client(forUDID: booted.udid)
    // Start at opposite corners of a small box around the center; pinch in.
    try client.twoFingerDown(f1: CGPoint(x: 0.3, y: 0.3), f2: CGPoint(x: 0.7, y: 0.7))
    try client.twoFingerDown(f1: CGPoint(x: 0.4, y: 0.4), f2: CGPoint(x: 0.6, y: 0.6))
    try client.twoFingerUp(f1: CGPoint(x: 0.4, y: 0.4), f2: CGPoint(x: 0.6, y: 0.6))
}

@Test
func keyboardKeyDownAndUpSucceed() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let client = try SimHIDClient.client(forUDID: booted.udid)
    // kVK_ANSI_A = 0
    try client.keyDown(keyCode: 0)
    try client.keyUp(keyCode: 0)
}

@Test
func eachHardwareButtonPressesCleanly() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let client = try SimHIDClient.client(forUDID: booted.udid)
    // Each press is ~100ms (50ms gap between down and up). Lock last so we
    // don't leave the device locked if the run errors midway. Siri is the
    // regression guard for the iOS 26 fix: the legacy ButtonEventSourceSiri
    // wedged the HID service, so Siri now routes through the Voice Command
    // consumer usage (page 0x0C / usage 0xCF) instead.
    for button in [
        CSBHardwareButton.home,
        .applePay,
        .siri,
        .sideButton,
        .lock
    ] {
        try client.pressHardwareButton(button)
    }
}

// The Digital Crown is watchOS-only and its SimulatorKit builder is
// optional (absent on older Xcode). The crown test below is gated on its
// availability AND on the booted device being a watch via
// `.enabled(if:)`, which *skips* (a `#require` would *fail*). So:
//   - `DEVICETERM_LIVE_DEVICE_FAMILY=watch make test-live` runs it;
//   - `make test-live` (default iPhone) skips it, and the non-watch
//     refusal is checked at the coordinator in
//     `CrownCapabilityLiveTests` instead. No test sends a crown event to
//     a non-watch through the bridge: after one, the next HID client
//     built in the process can't connect.
//   - a host whose SimulatorKit lacks the builder skips it, instead of
//     failing the whole live track.
private func crownBuilderAvailable() -> Bool {
    SimHIDClient.isDigitalCrownAvailable()
}

private func bootedDeviceIsWatch() -> Bool {
    let identifier = (try? SimDeviceHandle.singleBootedDevice())?
        .deviceTypeIdentifier ?? ""
    return identifier.lowercased().contains("watch")
}

@Test(.enabled(if: crownBuilderAvailable() && bootedDeviceIsWatch()))
func crownRotationScrollsCleanlyOnWatch() throws {
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let client = try SimHIDClient.client(forUDID: booted.udid)
    // On a watch the crown scrolls; visual movement is confirmed
    // via Tests/Manual/watchos-checklist.md. Here we assert both
    // directions send cleanly and don't wedge the HID port (a
    // follow-up touch still lands).
    try client.rotateCrown(delta: 30)
    try client.rotateCrown(delta: -30)
    let center = CGPoint(x: 0.5, y: 0.5)
    try client.tapDown(at: center)
    try client.tapUp(at: center)
}
