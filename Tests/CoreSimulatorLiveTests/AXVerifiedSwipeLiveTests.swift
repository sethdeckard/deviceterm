// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreSimulatorBridge
@testable import Daemon
import DaemonProtocol
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

/// A point read retains its diagnostic signature even when it is not a
/// Settings navigation row. Detail-pane buttons are not scroll witnesses.
private struct SettingsRowRead {
    let signature: String
    let frame: CGRect?
}

private func settingsRow(
    _ accessibility: SimAccessibility, at point: CGPoint, interface: CGSize, orientation: Orientation
) -> SettingsRowRead {
    // Point queries address the native panel even when the returned row
    // frames describe the landscape interface.
    let native = orientation.surfacePoint(displayedX: point.x, displayedY: point.y)
    let nativeSize = orientation == .portrait ? interface : CGSize(width: interface.height, height: interface.width)
    let hit = CGPoint(x: native.x * nativeSize.width, y: native.y * nativeSize.height)
    let displayed = CGPoint(x: point.x * interface.width, y: point.y * interface.height)
    guard let element = try? accessibility.elementAtPoint(hit) else {
        return SettingsRowRead(signature: "<none>", frame: nil)
    }
    let signature = AXSweep.dedupKey(element: element)
    guard let identifier = element["identifier"] as? String,
        identifier.hasPrefix("com.apple.settings."),
        let frame = element["frame"] as? [String: Any],
        let originX = frame["x"] as? Double, let originY = frame["y"] as? Double,
        let width = frame["w"] as? Double, let height = frame["h"] as? Double,
        [originX, originY, width, height].allSatisfy(\.isFinite),
        width > 0, height > 0 else {
        return SettingsRowRead(signature: signature, frame: nil)
    }
    let bounds = CGRect(x: originX, y: originY, width: width, height: height)
    guard bounds.contains(displayed), bounds.midX > 0, bounds.midX < interface.width else {
        return SettingsRowRead(signature: signature, frame: nil)
    }
    return SettingsRowRead(signature: signature, frame: bounds)
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

/// Find the navigation column from point queries: on iPad the screen
/// center belongs to the detail pane, and the tree can omit sidebar rows.
private func settingsListPoint(
    _ accessibility: SimAccessibility, interface: CGSize, orientation: Orientation
) throws -> CGPoint {
    var observations: [String] = []
    for attempt in 0..<20 {
        observations.removeAll()
        for step in 1...19 {
            let point = CGPoint(x: Double(step) * 0.05, y: 0.5)
            let row = settingsRow(accessibility, at: point, interface: interface, orientation: orientation)
            observations.append("\(point.x): \(row.signature)")
            if let frame = row.frame {
                return CGPoint(x: frame.midX / interface.width, y: point.y)
            }
        }
        if attempt < 19 { Thread.sleep(forTimeInterval: 0.5) }
    }
    throw SettingsRowFailure(details: "no Settings navigation row: \(observations.joined(separator: "; "))")
}

private struct SettingsRowFailure: Error {
    let details: String
}

/// Require two matching valid reads half a second apart to reduce launch-layout
/// races. Keep the query point fixed when comparing signatures.
private func settledSettingsRow(
    _ accessibility: SimAccessibility, at point: CGPoint, interface: CGSize, orientation: Orientation
) throws -> String {
    var previous: String?
    var signature = "<none>"
    for attempt in 0..<20 {
        let row = settingsRow(accessibility, at: point, interface: interface, orientation: orientation)
        signature = row.signature
        if row.frame != nil, signature == previous { return signature }
        previous = row.frame == nil ? nil : signature
        if attempt < 19 { Thread.sleep(forTimeInterval: 0.5) }
    }
    throw SettingsRowFailure(details: "no stable Settings row at \(point): \(signature)")
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
    // A foldable's fixed digitizer target reaches only one of its panels, and
    // which one varies from boot to boot, so address the lit panel as the
    // daemon does. Reads go to the same panel, so both halves judge one screen.
    if SimDisplayHandle.deviceHasMultiplePanels(udid: booted.udid) {
        let display = try SimDisplayHandle.handle(forUDID: booted.udid)
        try display.start { _ in }
        Thread.sleep(forTimeInterval: 0.5)
        client.touchScreenID = display.boundScreenID
        accessibility.displayID = display.boundScreenID
        display.stop()
    }
    try #require(waitForAXServer(accessibility, client: client), "the AX server never answered")

    dismissFirstBootAlert(client, accessibility: accessibility)
    // The entire sidebar fits on a portrait iPad, so even a delivered
    // swipe springs back without moving a row. Landscape makes it overflow.
    let orientation: Orientation = DeviceFamilyClassifier.classify(booted.deviceTypeIdentifier) == .pad
        ? .landscapeLeft : .portrait
    let purple = try SimPurpleHID.client(forUDID: booted.udid)
    if orientation != .portrait {
        try purple.rotate(to: orientation.bridgeValue)
        Thread.sleep(forTimeInterval: 3.0)
    }
    defer {
        if orientation != .portrait {
            try? purple.rotate(to: Orientation.portrait.bridgeValue)
            Thread.sleep(forTimeInterval: 3.0)
        }
    }
    let interface = try relaunchSettings(udid: booted.udid, accessibility: accessibility)
    if orientation != .portrait {
        try #require(interface.width > interface.height, "Settings never adopted landscape: \(interface)")
    }
    let point = try settingsListPoint(accessibility, interface: interface, orientation: orientation)
    let before = try settledSettingsRow(accessibility, at: point, interface: interface, orientation: orientation)

    // The daemon's own swipe shape: interpolated downs at ~60 Hz, a lift
    // at the end. `PaneCoordinator.swipe` paces a 300 ms gesture this way.
    // Direct HID addresses the native portrait panel; AX returns frames in
    // displayed coordinates. Convert the swipe using the daemon’s input mapping.
    let nativeStart = orientation.surfacePoint(displayedX: point.x, displayedY: 0.70)
    let nativeEnd = orientation.surfacePoint(displayedX: point.x, displayedY: 0.40)
    let start = CGPoint(x: nativeStart.x, y: nativeStart.y)
    let end = CGPoint(x: nativeEnd.x, y: nativeEnd.y)
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

    // Settle, then read the same point back. The read must be a Settings row of
    // its own: an AX read that failed or found nothing is not evidence the
    // list moved, and counting it as a change would pass a dead swipe. A
    // send that was accepted and discarded leaves the row identical, which
    // is the failure this test exists to catch.
    Thread.sleep(forTimeInterval: 1.5)
    let after = try settledSettingsRow(accessibility, at: point, interface: interface, orientation: orientation)
    #expect(after != before, "the swipe did not scroll at \(point) (before: \(before); after: \(after))")
}
