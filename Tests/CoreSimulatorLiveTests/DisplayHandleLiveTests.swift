// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import Foundation
import IOSurface
import Testing

// Live display streaming against a booted sim. Deliberate `make test-live`
// track. The lookup/error-path tests are hermetic and stay in
// CoreSimulatorBridgeTests.
private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

/// Poll `handle.currentSurface()` until it goes non-nil or the
/// timeout expires. Returns nil on timeout. The bridge fires
/// synchronously on `start` if a surface is already bound, so the
/// first read usually succeeds; the polling loop covers the
/// cold-boot transient where the proxy hasn't allocated its surface
/// yet.
private func waitForSurface(_ handle: SimDisplayHandle, timeoutSeconds: Double = 5) -> IOSurfaceRef? {
    let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
    while Date() < deadline {
        if let ref = handle.currentSurface() { return ref }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return nil
}

@Test
func startAgainstBootedDeviceBindsSurface() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let handle = try SimDisplayHandle.handle(forUDID: booted.udid)
    try handle.start { _ in /* ignore — currentSurface is the signal */ }
    defer { handle.stop() }

    let ref = waitForSurface(handle)
    #expect(ref != nil, "no surface bound within timeout")
}

@Test
func displaySizeReflectsBoundRenderable() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let handle = try SimDisplayHandle.handle(forUDID: booted.udid)
    try handle.start { _ in /* ignore */ }
    defer { handle.stop() }
    _ = waitForSurface(handle)  // ensure the renderable is bound
    let size = handle.displaySize
    #expect(size.width > 0, "displaySize.width was \(size.width)")
    #expect(size.height > 0, "displaySize.height was \(size.height)")
}

@Test
func displayOrientationSeedsAndFollowsARotation() throws {
    // The presented orientation is readable at attach and pushed on
    // change. Drives the rotation through the bridge's own HID path rather
    // than an external tool, so the test needs nothing but a booted sim.
    //
    // Whether the display actually follows depends on the foreground app:
    // the Home Screen doesn't rotate on iPhone. The seed must be cardinal,
    // and any delivered change must also be cardinal; the test does not
    // require a turn the interface may refuse.
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let handle = try SimDisplayHandle.handle(forUDID: booted.udid)
    try handle.start { _ in /* ignore */ }
    defer { handle.stop() }
    _ = waitForSurface(handle)  // ensure the renderable is bound

    let observed = OrientationLog()
    try handle.startOrientation(
        callback: { observed.append($0) },
        queue: DispatchQueue(label: "live.display-orientation")
    )
    // Seed *after* registering, the order the gap-free contract requires.
    let seed = handle.currentDisplayOrientation
    #expect(seed != .unknown, "no orientation vended by a bound display")

    let purple = try SimPurpleHID.client(forUDID: booted.udid)
    try purple.rotate(to: .landscapeLeft)
    Thread.sleep(forTimeInterval: 1.5)
    try purple.rotate(to: .portrait)
    Thread.sleep(forTimeInterval: 1.5)

    // Every delivered value is cardinal: `unknown` is filtered in the
    // bridge and must never reach a consumer.
    #expect(observed.values.allSatisfy { $0 != .unknown })
    // And the reader still agrees with itself after the callbacks settle.
    #expect(handle.currentDisplayOrientation != .unknown)
}

/// Thread-safe sink for callbacks delivered on the bridge's queue.
private final class OrientationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CSBDisplayOrientation] = []

    var values: [CSBDisplayOrientation] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ orientation: CSBDisplayOrientation) {
        lock.lock(); defer { lock.unlock() }
        storage.append(orientation)
    }
}

@Test
func orientationObservationRequiresAStartedHandle() throws {
    // Both ride the same display proxy, which the surface subscription is
    // what resolves, so observing before `start` is refused rather than
    // silently returning a handle that never delivers.
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let handle = try SimDisplayHandle.handle(forUDID: booted.udid)
    #expect(throws: (any Error).self) {
        try handle.startOrientation(callback: { _ in }, queue: .main)
    }
}

@Test
func stopIsIdempotent() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let handle = try SimDisplayHandle.handle(forUDID: booted.udid)
    try handle.start { _ in /* ignore */ }
    handle.stop()
    handle.stop()  // second stop is a no-op
    // After stop, the renderable is cleared and currentSurface() reads nil.
    #expect(handle.currentSurface() == nil)
}
