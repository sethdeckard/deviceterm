// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import Daemon
import DaemonProtocol
import Foundation
import IOSurface
import Testing

// Live display streaming against a booted sim. Deliberate `make test-live`
// track. The lookup/error-path tests are hermetic and stay in
// CoreSimulatorBridgeTests.
private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

/// Whether the track's actual booted device is a watch. Read device identity
/// rather than the family-selection environment variable: the default track
/// can fall back to another family when no iPhone or iPad is installed.
private func bootedDeviceIsWatch() -> Bool {
    let identifier = (try? SimDeviceHandle.singleBootedDevice())?
        .deviceTypeIdentifier ?? ""
    return DeviceFamilyClassifier.classify(identifier) == .watch
}

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

/// Whether the booted device vends more than one panel. Keyed off the
/// device-type identifier rather than a candidate count, which the handle
/// deliberately doesn't expose.
private func bootedDeviceIsFoldable() -> Bool {
    let identifier = (try? SimDeviceHandle.singleBootedDevice())?
        .deviceTypeIdentifier.lowercased() ?? ""
    return identifier.contains("duo")
}

/// Whether a surface reports visible content on a coarse grid. Mirrors the
/// bridge's own tiebreaker so the test measures what the picker measures.
/// Returns false when the surface cannot be sampled as well as when it is
/// black.
private func surfaceHasContent(_ surface: IOSurfaceRef) -> Bool {
    let width = IOSurfaceGetWidth(surface)
    let height = IOSurfaceGetHeight(surface)
    guard width > 0, height > 0 else { return false }
    guard IOSurfaceLock(surface, .readOnly, nil) == kIOReturnSuccess else { return false }
    defer { IOSurfaceUnlock(surface, .readOnly, nil) }
    let base = IOSurfaceGetBaseAddress(surface)
    let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
    guard bytesPerRow >= width * 4 else { return false }
    let pixels = base.assumingMemoryBound(to: UInt8.self)
    let stepX = max(1, width / 64)
    let stepY = max(1, height / 64)
    for y in stride(from: 0, to: height, by: stepY) {
        for x in stride(from: 0, to: width, by: stepX) {
            let offset = y * bytesPerRow + x * 4
            if pixels[offset] != 0 || pixels[offset + 1] != 0 || pixels[offset + 2] != 0 {
                return true
            }
        }
    }
    return false
}

@Test
func boundPanelIdentityIsReportedAfterStart() throws {
    // Every device has at least one screen, so a bound handle can always
    // name the panel it mirrors. On a foldable these are what tell the two
    // display descriptors apart.
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let handle = try SimDisplayHandle.handle(forUDID: booted.udid)
    try handle.start { _ in }
    defer { handle.stop() }
    _ = waitForSurface(handle)

    #expect(handle.boundScreenID > 0, "bound panel reported no screen id")
    let uniqueId = try #require(handle.boundScreenUniqueId, "bound panel reported no uniqueId")
    #expect(!uniqueId.isEmpty)
}

@Test(.enabled(if: bootedDeviceIsFoldable()))
func foldableBindsTheLitPanel() throws {
    // A foldable vends one sized descriptor per panel and powers exactly one
    // of them. Binding by enumeration order can land on the dark one, which
    // renders a black pane; the picker breaks the tie on content instead.
    // Asserting the bound surface has content is the same check, one layer up.
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let handle = try SimDisplayHandle.handle(forUDID: booted.udid)
    try handle.start { _ in }
    defer { handle.stop() }

    let surface = try #require(waitForSurface(handle), "no surface bound within timeout")
    let panel = handle.boundScreenID
    #expect(
        surfaceHasContent(surface),
        "no content on bound panel \(panel): unreadable, black, or inactive"
    )
}

@Test
func panelCountMatchesTheBootedDevice() throws {
    // What arms the fold-following search. A one-panel device must report one,
    // or every rotation on an ordinary phone starts a search for a swap that
    // cannot happen.
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let handle = try SimDisplayHandle.handle(forUDID: booted.udid)
    try handle.start { _ in }
    defer { handle.stop() }
    _ = waitForSurface(handle)

    #expect(handle.hasMultiplePanels == bootedDeviceIsFoldable())
}

@Test
func rebindingAnUnchangedPostureKeepsTheBoundPanel() throws {
    // The posture is settled, so the bound panel is the lit one and asking to
    // move off it reports no change. This is what makes the search safe to run
    // on every screen-properties delivery: it only ever acts on a panel that
    // has actually gone dark.
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let handle = try SimDisplayHandle.handle(forUDID: booted.udid)
    try handle.start { _ in }
    defer { handle.stop() }
    _ = waitForSurface(handle)

    let panel = handle.boundScreenUniqueId
    #expect(!handle.rebindToLitPanel())
    #expect(handle.boundScreenUniqueId == panel)
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

@Test(.enabled(if: !bootedDeviceIsWatch()))
func displayOrientationSeedsAndFollowsARotation() throws {
    // The presented orientation is readable at attach and pushed on
    // change. Drives the rotation through the bridge's own HID path rather
    // than an external tool, so the test needs nothing but a booted sim.
    //
    // Whether the display actually follows depends on the foreground app:
    // the Home Screen doesn't rotate on iPhone. The seed must be cardinal,
    // and any delivered change must also be cardinal; the test does not
    // require a turn the interface may refuse. A watch's presentation is
    // fixed, and its display proxy may report uiOrientation 0. The
    // display-binding tests still run for watches; Crown tests run when
    // SimulatorKit exposes the optional builder.
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

@Test
func pausingFramesKeepsTheDisplayBoundAndResumeSeedsAFrame() throws {
    let booted = try #require(try? SimDeviceHandle.singleBootedDevice())
    let handle = try SimDisplayHandle.handle(forUDID: booted.udid)
    let deliveries = DisplayInvalidationCount()
    try handle.startInvalidations { _ in deliveries.bump() }
    defer { handle.stop() }
    _ = try #require(waitForSurface(handle))
    let panel = handle.boundScreenUniqueId
    let orientation = handle.currentDisplayOrientation
    handle.pauseFrames()
    let pausedCount = deliveries.count
    Thread.sleep(forTimeInterval: 0.1)
    #expect(deliveries.count == pausedCount)
    #expect(handle.boundScreenUniqueId == panel)
    #expect(handle.currentDisplayOrientation == orientation)
    #expect(handle.currentSurface() != nil)
    try handle.startInvalidations { _ in deliveries.bump() }
    #expect(deliveries.count > pausedCount)
    #expect(handle.boundScreenUniqueId == panel)
}

/// Bridge callbacks access the counter only on this serial queue.
private final class DisplayInvalidationCount: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.display-invalidation")
    private var value = 0
    var count: Int { queue.sync { value } }
    func bump() { queue.sync { value += 1 } }
}
