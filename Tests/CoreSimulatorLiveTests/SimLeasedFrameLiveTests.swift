// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
@testable import Daemon
import Foundation
import IOSurface
import Testing

// Leased simulator frames against a booted sim. Deliberate `make test-live`
// track. The pump's exhaustion policy is driven hermetically in
// `SimFramePumpTests`; what needs a live display is that the bridge callback
// feeds the pump at all, and that what it publishes carries a lease the pool
// will honour.
private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

private func bootedBackend() throws -> SimDeviceBackend {
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    return SimDeviceBackend(
        udid: booted.udid,
        displayHandle: try SimDisplayHandle.handle(forUDID: booted.udid),
        hidClient: try SimHIDClient.client(forUDID: booted.udid),
        purpleClient: try SimPurpleHID.client(forUDID: booted.udid)
    )
}

/// Collects published frames off the pump's task. Retaining them holds their
/// pool slots, which keeps a captured lease valid for the assertions below.
///
/// `@unchecked Sendable`: every access goes through `lock`.
private final class FrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [PublishedSurface] = []
    private var failures: [String] = []

    var count: Int { lock.withLock { frames.count } }
    var hasFrame: Bool { lock.withLock { !frames.isEmpty } }
    var leasedCount: Int { lock.withLock { frames.filter { $0.lease != nil }.count } }
    var firstLease: LeaseMetadata? { lock.withLock { frames.first?.lease } }
    var failure: String? { lock.withLock { failures.first } }

    func publish(_ frame: PublishedSurface) { lock.withLock { frames.append(frame) } }
    func fail(_ reason: String) { lock.withLock { failures.append(reason) } }
}

private func waitUntil(_ predicate: @Sendable () -> Bool, seconds: Double = 5) -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while Date() < deadline {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return predicate()
}

@Test
func aBootedSimPublishesLeasedFrames() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let backend = try bootedBackend()
    let sink = FrameSink()
    try backend.startFrames(onFrame: sink.publish, onFatal: sink.fail, onDisconnect: {})
    defer { backend.stopFrames() }

    #expect(waitUntil { sink.hasFrame }, "no frame published within timeout")
    // Stop before asserting: this sink never releases a frame, so leaving the
    // stream running would exhaust the pool and fail the pane out from under
    // the assertions. That policy has its own coverage.
    backend.stopFrames()

    // Simulator frames carry lease metadata, enabling acknowledged delivery
    // and bounding what a stalled consumer can cost the daemon.
    #expect(sink.leasedCount == sink.count)
    #expect(sink.failure == nil)
}

@Test
func aSimBackendRoutesLeaseRegistrationToItsPool() async throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let backend = try bootedBackend()
    let sink = FrameSink()
    try backend.startFrames(onFrame: sink.publish, onFatal: sink.fail, onDisconnect: {})
    defer { backend.stopFrames() }
    #expect(waitUntil { sink.hasFrame }, "no frame published within timeout")
    backend.stopFrames()

    let lease = try #require(sink.firstLease)
    let token = UUID()
    // A token the pool has never seen can reserve nothing.
    #expect(await lease.acquireHold(token) == nil)
    // Registering through the backend reaches the pool behind it, which is
    // what the lease-overlay forwarders exist to do. A sim backend inheriting
    // the protocol's no-op defaults would leave this nil.
    await backend.registerLeaseToken(token, connectionId: 1)
    #expect(await lease.acquireHold(token) != nil)
}
