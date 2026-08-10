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
