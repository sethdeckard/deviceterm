// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// Surface-lease wiring: the subscription-registration path a device
// pane's leased surface pool rides on. These pin: a device pane registers
// its subscription's lease token; the initial replay is token-targeted (a
// new subscription's frame is re-delivered only to itself, not every
// existing token); the `pane.surfaceRelease` handler routes the peer
// connection id (not the payload) to the pool; the grant worker commits a
// hold before the send and frees it on a watermark; and the subscribe ack
// carries the correlation token over a context (XPC) but not without one
// (UDS).

// swiftlint:disable unneeded_throws_rethrows

private struct ReleaseCall: Equatable {
    let token: UUID
    let epoch: UInt64
    let lowestHeld: UInt64
    let connectionId: UInt64
}

/// A device backend that owns a real `LeasedSurfacePool` (like
/// `RealDeviceBackend`) and records the lease-bookkeeping calls made
/// against it. `@unchecked Sendable`: each test drives it with one awaited
/// call at a time and reads the recording arrays only after those awaits
/// return, so every access is ordered: there is no concurrent mutation to
/// synchronize.
private final class LeasingMockBackend: DeviceBackend, @unchecked Sendable {
    let capabilities = DeviceBackendCapabilities.physicalDevice.withoutLocation
    let pool = LeasedSurfacePool(slotCount: 6)
    private(set) var registeredTokens: [(token: UUID, connectionId: UInt64)] = []
    private(set) var releaseCalls: [ReleaseCall] = []
    private(set) var drainedTokens: [UUID] = []
    private(set) var orphanedTokens: [UUID] = []
    private(set) var onSurface: (@Sendable (PublishedSurface) -> Void)?

    func startFrames(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void,
        onDisconnect: @escaping @Sendable () -> Void
    ) throws {
        onSurface = onFrame
    }
    func stopFrames() {}
    func pixelDimensions() -> (Int?, Int?) { (nil, nil) }

    // No display or reply to observe; rotation confirmation is unsupported.
    func startDisplayOrientation(onChange: @escaping @Sendable (Orientation) -> Void) -> Bool { false }
    func stopDisplayOrientation() {}
    func currentDisplayOrientation() -> Orientation? { nil }
    func tapDown(at point: CGPoint, generation: UInt64) throws {}
    func tapUp(at point: CGPoint, generation: UInt64) throws {}
    func twoFingerDown(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws {}
    func twoFingerUp(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws {}
    func keyDown(hidUsage: UInt32, generation: UInt64) throws {}
    func keyUp(hidUsage: UInt32, generation: UInt64) throws {}
    func pressHardwareButton(_ button: HardwareButton, generation: UInt64) throws {}
    func rotate(
        target: RotationTarget,
        confirmedOrientation: Orientation?,
        generation: UInt64
    ) throws -> BackendRotationOutcome {
        .confirmationUnsupported(target: target.orientation)
    }
    func rotateCrown(delta: Double, generation: UInt64) throws {}
    func accessibilityFrontmostTree() throws -> [String: Any] { [:] }
    func accessibilityElement(at pixelPoint: CGPoint) throws -> [String: Any] { [:] }
    func shutdownBackend() {}

    func registerLeaseToken(_ token: UUID, connectionId: UInt64) async {
        registeredTokens.append((token, connectionId))
        await pool.registerToken(token, connectionId: connectionId)
    }
    func unregisterLeaseTokenIfUnused(_ token: UUID) async -> Bool {
        await pool.unregisterTokenIfUnused(token)
    }
    func releaseWatermark(token: UUID, epoch: UInt64, lowestHeld: UInt64, connectionId: UInt64) async {
        releaseCalls.append(
            ReleaseCall(token: token, epoch: epoch, lowestHeld: lowestHeld, connectionId: connectionId)
        )
        await pool.applyWatermark(token: token, epoch: epoch, lowestHeld: lowestHeld, connectionId: connectionId)
    }
    func drain(token: UUID) async {
        drainedTokens.append(token)
        await pool.beginDrain(token)
    }
    func orphan(token: UUID) async {
        orphanedTokens.append(token)
        await pool.orphan(token)
    }
}
// swiftlint:enable unneeded_throws_rethrows

private extension PaneCoordinator {
    func createDevicePane(
        deviceId: String,
        sessionId: UUID,
        backend: LeasingMockBackend
    ) async throws -> PaneCreateResult {
        try await createPane(
            target: .device(deviceId: deviceId),
            sessionId: sessionId,
            acquire: { AcquiredBackend(backend: backend, family: "phone", deviceType: "iPhone") }
        )
    }
}

private func makeTestPublished() throws -> PublishedSurface {
    let raw = try #require(SurfaceCopy.makeSurface(width: 4, height: 4))
    return PublishedSurface(owned: LeasedSurface(surface: RetainedSurface(raw)), lease: nil)
}

/// Counts side-band deliveries into one subscription's surface lane.
/// `@unchecked Sendable`: `count` is read/written only under `lock`.
private final class DeliveryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func bump() { lock.lock(); count += 1; lock.unlock() }
}

/// Records the synchronous sends the registry's grant worker performs.
/// `@unchecked Sendable`: `infos` is read/written only under `lock`.
private final class SendBox: @unchecked Sendable {
    private let lock = NSLock()
    private var infos: [PaneSubscriptionRegistry.SurfaceSendInfo] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return infos.count }
    var sequences: [UInt64] { lock.lock(); defer { lock.unlock() }; return infos.map(\.sequence) }
    var last: PaneSubscriptionRegistry.SurfaceSendInfo? {
        lock.lock(); defer { lock.unlock() }; return infos.last
    }
    func record(_ info: PaneSubscriptionRegistry.SurfaceSendInfo) {
        lock.lock(); infos.append(info); lock.unlock()
    }
}

private func pollUntil(_ predicate: @Sendable () async -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(0.5)
    while Date() < deadline {
        if await predicate() { return true }
        try await Task.sleep(nanoseconds: 3_000_000)
    }
    return await predicate()
}

@Test("a leased device frame commits a hold before the send and frees it on a watermark")
func leasedDeliveryCommitsHoldThenReleasesOnWatermark() async throws {
    let pool = LeasedSurfacePool(slotCount: 6)
    let registry = PaneSubscriptionRegistry(leasingEnabled: true)
    let paneId = UUID()
    let sends = SendBox()
    let token = UUID()
    await registry.registerSurfaceDelivery(
        paneId: paneId,
        connectionId: 1,
        subscriptionId: token,
        surfaceDelivery: { info in sends.record(info) }
    )
    await registry.activate(subscriptionId: token)
    await pool.registerToken(token, connectionId: 1)
    let published = try #require(await pool.acquire(width: 4, height: 4))
    let generation = try #require(published.lease?.generation)

    await registry.deliverSurface(paneId: paneId, published: published, sequence: generation)
    #expect(try await pollUntil { sends.count >= 1 })

    let info = try #require(sends.last)
    #expect(info.leased)
    #expect(info.subscriptionToken == token)
    #expect(info.sequence == generation)
    // The hold was committed (not merely reserved) before the send.
    var held = await pool.holders(epoch: info.leaseEpoch, generation: generation)
    #expect(held.contains(.subscription(token)))

    // A watermark past the generation frees the committed hold.
    _ = await pool.applyWatermark(
        token: token,
        epoch: info.leaseEpoch,
        lowestHeld: generation &+ 1,
        connectionId: 1
    )
    held = await pool.holders(epoch: info.leaseEpoch, generation: generation)
    #expect(held.contains(.subscription(token)) == false)
}

@Test("the grant worker exposes paced frames in reservation order")
func leasedDeliveryPreservesGenerationOrder() async throws {
    let pool = LeasedSurfacePool(slotCount: 6)
    let registry = PaneSubscriptionRegistry(leasingEnabled: true)
    let paneId = UUID()
    let sends = SendBox()
    let token = UUID()
    await registry.registerSurfaceDelivery(
        paneId: paneId,
        connectionId: 1,
        subscriptionId: token,
        surfaceDelivery: { info in sends.record(info) }
    )
    await registry.activate(subscriptionId: token)
    await pool.registerToken(token, connectionId: 1)

    // Pace one frame per delivery (wait for each send) so the worker never
    // coalesces: every generation is exposed, in order.
    var generations: [UInt64] = []
    for index in 0..<4 {
        let published = try #require(await pool.acquire(width: 4, height: 4))
        let generation = try #require(published.lease?.generation)
        generations.append(generation)
        await registry.deliverSurface(paneId: paneId, published: published, sequence: generation)
        let expectedCount = index + 1
        #expect(try await pollUntil { sends.count == expectedCount })
    }
    #expect(sends.sequences == generations)
}

@Test("under backpressure the worker coalesces to the newest, in order, dropping intermediates")
func leasedDeliveryCoalescesUnderBackpressure() async throws {
    let pool = LeasedSurfacePool(slotCount: 8)
    let registry = PaneSubscriptionRegistry(leasingEnabled: true)
    let paneId = UUID()
    let sends = SendBox()
    let token = UUID()
    await registry.registerSurfaceDelivery(
        paneId: paneId,
        connectionId: 1,
        subscriptionId: token,
        surfaceDelivery: { info in sends.record(info) }
    )
    await registry.activate(subscriptionId: token)
    await pool.registerToken(token, connectionId: 1)

    // Burst without pacing: the bounded (one running + one newest-queued)
    // worker may drop intermediate generations, but what it does send is
    // monotonic and ends on the newest.
    var generations: [UInt64] = []
    for _ in 0..<6 {
        let published = try #require(await pool.acquire(width: 4, height: 4))
        let generation = try #require(published.lease?.generation)
        generations.append(generation)
        await registry.deliverSurface(paneId: paneId, published: published, sequence: generation)
    }
    let newest = try #require(generations.max())
    #expect(try await pollUntil { sends.sequences.last == newest })
    // Never a stale playback: the sent sequence is strictly increasing.
    let sent = sends.sequences
    #expect(sent == sent.sorted())
    #expect(Set(sent).count == sent.count)
    #expect(sent.count <= generations.count)
}

@Test("kill-switched leasing delivers a device frame bare, taking no hold")
func killSwitchedLeasingSendsBare() async throws {
    let pool = LeasedSurfacePool(slotCount: 6)
    let registry = PaneSubscriptionRegistry(leasingEnabled: false)
    let paneId = UUID()
    let sends = SendBox()
    let token = UUID()
    await registry.registerSurfaceDelivery(
        paneId: paneId,
        connectionId: 1,
        subscriptionId: token,
        surfaceDelivery: { info in sends.record(info) }
    )
    await registry.activate(subscriptionId: token)
    await pool.registerToken(token, connectionId: 1)
    let published = try #require(await pool.acquire(width: 4, height: 4))
    let generation = try #require(published.lease?.generation)

    await registry.deliverSurface(paneId: paneId, published: published, sequence: generation)
    #expect(try await pollUntil { sends.count >= 1 })
    let info = try #require(sends.last)
    #expect(info.leased == false)
    let held = await pool.holders(epoch: try #require(published.lease?.epoch), generation: generation)
    #expect(held.contains(.subscription(token)) == false)
}

@Test("a device pane registers its subscription's lease token with the pool")
func deviceSubscribeRegistersLeaseToken() async throws {
    let registry = PaneSubscriptionRegistry()
    let coordinator = PaneCoordinator(subscriptionRegistry: registry)
    let backend = LeasingMockBackend()
    let result = try await coordinator.createDevicePane(
        deviceId: "dev-reg",
        sessionId: UUID(),
        backend: backend
    )

    let token = UUID()
    let lifecycle = SubscriptionLifecycle()
    let context = SubscriptionContext(
        subscriptionToken: token,
        connectionId: 7,
        lifecycle: lifecycle,
        surfaceDelivery: { _ in }
    )
    _ = try await coordinator.subscribe(paneId: result.paneId, as: .guiPeer, context: context)

    #expect(backend.registeredTokens.count == 1)
    #expect(backend.registeredTokens.first?.token == token)
    #expect(backend.registeredTokens.first?.connectionId == 7)
    #expect(await backend.pool.tokenState(token) == .active)
}

@Test("the initial replay is token-targeted — a new subscription doesn't re-deliver to existing ones")
func initialReplayTargetsOnlyTheNewToken() async throws {
    let registry = PaneSubscriptionRegistry()
    let coordinator = PaneCoordinator(subscriptionRegistry: registry)
    let backend = LeasingMockBackend()
    let result = try await coordinator.createDevicePane(
        deviceId: "dev-replay",
        sessionId: UUID(),
        backend: backend
    )
    let onSurface = try #require(backend.onSurface)

    // Warm up: a JSON subscriber lets us drive one frame through the pump
    // and wait until `currentSurface`/`lastSequence` are set, so a later
    // subscribe has something to replay.
    let (warmId, warmStream) = try await coordinator.subscribe(paneId: result.paneId, as: .guiPeer)
    var warm = warmStream.makeAsyncIterator()
    onSurface(try makeTestPublished())
    while let event = await warm.next() {
        if case .surfaceChanged = event { break }
    }

    // Subscription A supplies the context delivery lane. The coordinator
    // registers its hook after authorization.
    let probeA = DeliveryProbe()
    let tokenA = UUID()
    _ = try await coordinator.subscribe(
        paneId: result.paneId,
        as: .guiPeer,
        context: SubscriptionContext(
            subscriptionToken: tokenA,
            connectionId: 1,
            lifecycle: SubscriptionLifecycle(),
            surfaceDelivery: { _ in probeA.bump() }
        )
    )
    #expect(probeA.value == 1)

    // Subscription B subscribes: its replay must reach B only, not A.
    let probeB = DeliveryProbe()
    let tokenB = UUID()
    _ = try await coordinator.subscribe(
        paneId: result.paneId,
        as: .guiPeer,
        context: SubscriptionContext(
            subscriptionToken: tokenB,
            connectionId: 2,
            lifecycle: SubscriptionLifecycle(),
            surfaceDelivery: { _ in probeB.bump() }
        )
    )
    #expect(probeB.value == 1)
    #expect(probeA.value == 1)

    await coordinator.unsubscribe(paneId: result.paneId, subscriptionId: warmId)
}

@Test("pane.surfaceRelease routes the peer connection id, not the payload, to the pool")
func surfaceReleaseThreadsPeerConnectionId() async throws {
    let coordinator = PaneCoordinator()
    let backend = LeasingMockBackend()
    let result = try await coordinator.createDevicePane(
        deviceId: "dev-release",
        sessionId: UUID(),
        backend: backend
    )
    let handler = PaneMethods.surfaceRelease(paneCoordinator: coordinator)
    let params = try JSONEncoder().encode(
        SurfaceReleaseParams(
            paneId: result.paneId.uuidString,
            subscriptionToken: UUID().uuidString,
            leaseEpoch: 1,
            lowestHeld: 5
        )
    )

    // The peer connection id comes from the dispatch context, not the
    // payload: a leaked token from another peer can't release slots.
    let peer = DispatchPeerContext(transport: .xpc, connectionId: 42)
    _ = try await DispatchPeerContext.$current.withValue(peer) {
        try await handler(params)
    }
    #expect(backend.releaseCalls.count == 1)
    #expect(backend.releaseCalls.first?.connectionId == 42)
    #expect(backend.releaseCalls.first?.lowestHeld == 5)

    // With no dispatch context, the id defaults to 0 (which no token
    // registers under, so the pool rejects it).
    _ = try await handler(params)
    #expect(backend.releaseCalls.last?.connectionId == 0)
}

@Test("the subscribe ack carries the token with a context and omits it without one")
func subscribeAckCarriesTokenPerTransport() async throws {
    let registry = PaneSubscriptionRegistry()
    let coordinator = PaneCoordinator(subscriptionRegistry: registry)
    let backend = LeasingMockBackend()
    let result = try await coordinator.createDevicePane(
        deviceId: "dev-ack",
        sessionId: UUID(),
        backend: backend
    )
    let handler = PaneMethods.subscribe(paneCoordinator: coordinator)
    let params = try JSONEncoder().encode(PaneMethods.SubscribeParams(paneId: result.paneId.uuidString))

    // The handler derives its principal from dispatch context; bind a
    // validated GUI peer for this request (the pane's owner session is
    // discarded above). This is orthogonal to the XPC-vs-UDS
    // distinction the test exercises, which is the `context` (token) arg.
    let peer = DispatchPeerContext(transport: .xpc, connectionId: 0, validatedGUIPeer: true)

    // XPC: a context carries the token, which the ack echoes back.
    let token = UUID()
    let xpcResult = try await DispatchPeerContext.$current.withValue(peer) {
        try await handler(
            params,
            SubscriptionContext(
                subscriptionToken: token,
                connectionId: 3,
                lifecycle: SubscriptionLifecycle(),
                surfaceDelivery: { _ in }
            )
        )
    }
    let xpcAck = try JSONDecoder().decode(PaneSubscribeAck.self, from: xpcResult.initialResult)
    #expect(xpcAck.success)
    #expect(xpcAck.subscriptionToken == token.uuidString)

    // UDS: no context, no token in the ack. onCancel then unsubscribes.
    let udsResult = try await DispatchPeerContext.$current.withValue(peer) {
        try await handler(params, nil)
    }
    let udsAck = try JSONDecoder().decode(PaneSubscribeAck.self, from: udsResult.initialResult)
    #expect(udsAck.subscriptionToken == nil)

    #expect(await coordinator.subscriberCount(paneId: result.paneId) == 2)
    udsResult.onCancel()
    // onCancel spins a detached unsubscribe Task; poll for it to land.
    var remaining = await coordinator.subscriberCount(paneId: result.paneId)
    let deadline = Date().addingTimeInterval(0.5)
    while remaining == 2, Date() < deadline {
        try await Task.sleep(nanoseconds: 5_000_000)
        remaining = await coordinator.subscriberCount(paneId: result.paneId)
    }
    #expect(remaining == 1)
}

@Test("deliverSurface(to:) reaches only the addressed subscription")
func targetedDeliverySurfaceReachesOneSubscription() async throws {
    let registry = PaneSubscriptionRegistry()
    let paneId = UUID()
    let probeA = DeliveryProbe()
    let probeB = DeliveryProbe()
    let tokenA = UUID()
    let tokenB = UUID()
    await registry.registerSurfaceDelivery(
        paneId: paneId,
        connectionId: 1,
        subscriptionId: tokenA,
        surfaceDelivery: { _ in probeA.bump() }
    )
    await registry.registerSurfaceDelivery(
        paneId: paneId,
        connectionId: 1,
        subscriptionId: tokenB,
        surfaceDelivery: { _ in probeB.bump() }
    )
    // Both active, so a delivery reaching only A is a *targeting* result,
    // not merely B being dormant.
    await registry.activate(subscriptionId: tokenA)
    await registry.activate(subscriptionId: tokenB)
    await registry.deliverSurface(to: tokenA, published: try makeTestPublished(), sequence: 1)
    #expect(probeA.value == 1)
    #expect(probeB.value == 0)
}
