// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreSimulatorBridge
@testable import Daemon
import Foundation
import Testing

// Does a HID send actually reach the guest? Every other live HID test
// asserts only that the send didn't throw, which is the same thing the
// daemon's receipts claim and exactly what a transport that accepts and
// discards satisfies. This one reads the result back over accessibility,
// a channel with nothing in common with HID.
//
// The test process creates the client after `make test-live` has booted
// the simulator, covering client registration after simulator startup, as
// happens after a helper replacement.

private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

/// The track boots a watch under `DEVICETERM_LIVE_DEVICE_FAMILY=watch` and
/// can fall back to another family when no iPhone or iPad is installed.
/// Only iOS and iPadOS have the touch-scrollable Settings list this test
/// reads, so it runs on those and skips elsewhere. Read from the booted
/// device rather than the environment, as the other gated tests do.
private func bootedDeviceHasSettingsList() -> Bool {
    let identifier = (try? SimDeviceHandle.singleBootedDevice())?
        .deviceTypeIdentifier ?? ""
    switch DeviceFamilyClassifier.classify(identifier) {
    case .phone, .pad:
        return true

    default:
        return false
    }
}

/// The element under the screen center, keyed the way the sweep keys
/// elements: role, identifier, label, and frame. Role and identifier alone
/// are not enough, because the bridge omits an empty identifier and two
/// static-text rows then read the same.
private func centerSignature(_ accessibility: SimAccessibility, interface: CGSize) -> String {
    let center = AXSweep.nativePixel(
        displayed: CGPoint(x: 0.5, y: 0.5),
        orientation: .portrait,
        interface: interface
    )
    guard let element = try? accessibility.elementAtPoint(center) else { return "<none>" }
    return AXSweep.dedupKey(element: element)
}

/// The first button in the frontmost tree, with its center in normalized
/// display space. AX frames are in interface points, so the division by
/// the interface size is the whole conversion in portrait.
private func firstButton(in tree: [String: Any], interface: CGSize) -> (label: String, point: CGPoint)? {
    if tree["role"] as? String == "Button",
        let frame = tree["frame"] as? [String: Any],
        let originX = frame["x"] as? Double, let originY = frame["y"] as? Double,
        let width = frame["w"] as? Double, let height = frame["h"] as? Double,
        width > 0, height > 0 {
        return (
            tree["label"] as? String ?? tree["identifier"] as? String ?? "?",
            CGPoint(x: (originX + width / 2) / interface.width, y: (originY + height / 2) / interface.height)
        )
    }
    for child in tree["children"] as? [[String: Any]] ?? [] {
        if let found = firstButton(in: child, interface: interface) { return found }
    }
    return nil
}

/// Build a client whose first send goes through, verified with a tap on the
/// status bar, which changes nothing. A client can come up with no
/// connected port right after another client's send in this process (the
/// crown no-op on a non-watch does that); a rebuild a moment later gets one.
private func connectedClient(udid: String) throws -> SimHIDClient {
    let statusBar = CGPoint(x: 0.5, y: 0.02)
    var lastError: any Error = CocoaError(.featureUnsupported)
    for attempt in 0..<8 {
        let client = try SimHIDClient.client(forUDID: udid)
        do {
            try client.tapDown(at: statusBar)
            try client.tapUp(at: statusBar)
            return client
        } catch {
            lastError = error
            if attempt < 7 { Thread.sleep(forTimeInterval: 1.0) }
        }
    }
    throw lastError
}

/// Wait for the AX server, which `simctl bootstatus` does not. Readiness is
/// a point query rather than the frontmost tree: the server answers points
/// before it has a frontmost app, and a home screen after a Home press has
/// none. A screen an earlier test left dark answers neither, so one Home
/// press through the client under test is allowed to wake it.
private func waitForAXServer(_ accessibility: SimAccessibility, client: SimHIDClient) -> Bool {
    let probe = CGPoint(x: 100, y: 300)
    var pressedHome = false
    for attempt in 0..<120 {
        if (try? accessibility.elementAtPoint(probe)) != nil { return true }
        if attempt == 10, !pressedHome {
            pressedHome = true
            try? client.pressHardwareButton(.home)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    return false
}

/// A fresh sim raises a location-permission alert over the home screen on
/// its first boot, and it sits over Settings too. Tap it away when a tree
/// shows it. Best effort: this is the client under test, so a dead one
/// leaves the alert up and the swipe then fails for that reason as well.
private func dismissFirstBootAlert(_ client: SimHIDClient, accessibility: SimAccessibility) {
    guard let tree = try? accessibility.frontmostTree(),
        let interface = AXSweep.interfaceSize(fromTree: tree),
        let button = firstButton(in: tree, interface: interface),
        button.label.localizedCaseInsensitiveContains("allow") else { return }
    try? client.tapDown(at: button.point)
    Thread.sleep(forTimeInterval: 0.05)
    try? client.tapUp(at: button.point)
    Thread.sleep(forTimeInterval: 1.5)
}

private struct SettingsLaunchFailure: Error {
    let status: Int32
}

/// Relaunch Settings, so the swipe below starts from the top of a list
/// long enough to scroll and specific enough to identify, and return its
/// interface size from its own tree. Terminating an app that is not running
/// is allowed to fail; the launch is not.
private func relaunchSettings(udid: String, accessibility: SimAccessibility) throws -> CGSize {
    for (arguments, mustSucceed) in [
        (["terminate", udid, "com.apple.Preferences"], false),
        (["launch", udid, "com.apple.Preferences"], true)
    ] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if mustSucceed, process.terminationStatus != 0 {
            throw SettingsLaunchFailure(status: process.terminationStatus)
        }
    }
    var interface: CGSize?
    for attempt in 0..<40 {
        if let tree = try? accessibility.frontmostTree() {
            interface = AXSweep.interfaceSize(fromTree: tree)
        }
        if interface != nil { break }
        if attempt < 39 { Thread.sleep(forTimeInterval: 0.5) }
    }
    return try #require(interface, "Settings never became the frontmost app")
}

/// Poll until a Settings row is under the center, so a verdict is never
/// about another screen or about an AX read that found nothing.
private func settingsRowAtCenter(_ accessibility: SimAccessibility, interface: CGSize) -> String {
    var signature = "<none>"
    for attempt in 0..<20 {
        signature = centerSignature(accessibility, interface: interface)
        if signature.contains("com.apple.settings.") { break }
        if attempt < 19 { Thread.sleep(forTimeInterval: 0.5) }
    }
    return signature
}

@Test(.enabled(if: bootedDeviceHasSettingsList()))
func aSwipeFromALateClientScrollsTheGuest() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let client = try connectedClient(udid: booted.udid)
    let accessibility = try SimAccessibility.client(forUDID: booted.udid)
    try #require(waitForAXServer(accessibility, client: client), "the AX server never answered")

    dismissFirstBootAlert(client, accessibility: accessibility)
    let interface = try relaunchSettings(udid: booted.udid, accessibility: accessibility)
    let before = settingsRowAtCenter(accessibility, interface: interface)
    try #require(before.contains("com.apple.settings."), "no Settings row under the center: \(before)")

    // The daemon's own swipe shape: interpolated downs at ~60 Hz, a lift
    // at the end. `PaneCoordinator.swipe` paces a 300 ms gesture this way.
    let start = CGPoint(x: 0.5, y: 0.70)
    let end = CGPoint(x: 0.5, y: 0.40)
    try client.tapDown(at: start)
    for step in 1...18 {
        Thread.sleep(forTimeInterval: 0.016)
        let progress = Double(step) / 18
        try client.tapDown(at: CGPoint(
            x: start.x + (end.x - start.x) * progress,
            y: start.y + (end.y - start.y) * progress
        ))
    }
    try client.tapUp(at: end)

    // Settle, then read the center back. The read must be a Settings row of
    // its own: an AX read that failed or found nothing is not evidence the
    // list moved, and counting it as a change would pass a dead swipe. A
    // send that was accepted and discarded leaves the row identical, which
    // is the failure this test exists to catch.
    Thread.sleep(forTimeInterval: 1.5)
    let after = settingsRowAtCenter(accessibility, interface: interface)
    try #require(after.contains("com.apple.settings."), "no Settings row under the center after the swipe: \(after)")
    #expect(after != before, "the swipe did not scroll the guest (before and after both \(before))")
}
