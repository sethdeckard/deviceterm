// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// The surface-lane no-further-send fence. Revoking a subscription
// unregisters its registry entry (the synchronous no-further-send point)
// BEFORE firing the lifecycle drain, whose device-pool teardown can
// suspend. So a surface injected while the pool drain is parked finds no
// entry and is not admitted: proving the fence lands ahead of the
// suspending drain, not after it.

// swiftlint:disable unneeded_throws_rethrows

/// A one-shot async gate: `wait()` suspends until `signal()`.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var open = false
    func wait() async {
        await withCheckedContinuation { cont in
            lock.lock()
            if open { lock.unlock(); cont.resume(); return }
            continuation = cont
            lock.unlock()
        }
    }
    func signal() {
        lock.lock()
        open = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}

/// Counts side-band sends. `@unchecked Sendable`: `count` under `lock`.
private final class SendCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    func bump() { lock.lock(); n += 1; lock.unlock() }
}

/// A device backend whose pool `drain` parks on a gate, so a test can hold
/// the lifecycle's pool teardown mid-suspension and probe what the registry
/// admits during that window.
private final class DrainParkingBackend: DeviceBackend, @unchecked Sendable {
    let capabilities = DeviceBackendCapabilities.physicalDevice.withoutLocation
    let pool = LeasedSurfacePool(slotCount: 6)
    let drainEntered = Gate()
    let drainRelease = Gate()

    func startFrames(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void,
        onDisconnect: @escaping @Sendable () -> Void
    ) throws {}
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
        await pool.registerToken(token, connectionId: connectionId)
    }
    // swiftlint:disable:next async_without_await
    func unregisterLeaseTokenIfUnused(_ token: UUID) async -> Bool {
        // Report "still holds something" so the drain path (which parks) is
        // taken rather than the unused fast-drop.
        false
    }
    // swiftlint:disable:next async_without_await
    func releaseWatermark(token: UUID, epoch: UInt64, lowestHeld: UInt64, connectionId: UInt64) async {}
    func drain(token: UUID) async {
        drainEntered.signal()
        await drainRelease.wait()
        await pool.beginDrain(token)
    }
    func orphan(token: UUID) async { await pool.orphan(token) }
}
// swiftlint:enable unneeded_throws_rethrows

private func makeLeasedPublished(pool: LeasedSurfacePool) async throws -> PublishedSurface {
    try #require(await pool.acquire(width: 4, height: 4))
}

@Test("revoking a subscription fences new surfaces before the suspending pool drain")
func surfaceFenceLandsBeforePoolDrain() async throws {
    let registry = PaneSubscriptionRegistry(leasingEnabled: true)
    let coordinator = PaneCoordinator(subscriptionRegistry: registry)
    let backend = DrainParkingBackend()
    let result = try await coordinator.createPane(
        target: .device(deviceId: "dev-fence"),
        sessionId: UUID(),
        acquire: { PaneCoordinator.AcquiredBackend(backend: backend, family: "phone", deviceType: "iPhone") }
    )

    let sends = SendCounter()
    let token = UUID()
    let context = SubscriptionContext(
        subscriptionToken: token,
        connectionId: 1,
        lifecycle: SubscriptionLifecycle(),
        surfaceDelivery: { _ in sends.bump() }
    )
    // Keep the subscription stream alive for the whole test: dropping it
    // would fire `onTermination` → an async unsubscribe that removes the
    // subscriber before `close` runs, so `revokeSubscriber` would find
    // nothing and the drain (the fence under test) would never fire.
    let (_, stream) = try await coordinator.subscribe(paneId: result.paneId, as: .guiPeer, context: context)

    // Close the pane: revokeSubscriber unregisters the token (the fence),
    // then fires the lifecycle drain, whose pool teardown calls
    // backend.drain, which parks.
    let closing = Task { _ = await coordinator.close(paneId: result.paneId, as: .guiPeer, mode: .detach) }

    // Wait until the pool drain has entered (parked). By now the registry
    // entry is already gone: the unregister ran first.
    await backend.drainEntered.wait()

    // Inject a fresh leased surface for the same token WHILE the drain is
    // parked. The entry is gone, so nothing is admitted.
    let published = try await makeLeasedPublished(pool: backend.pool)
    let generation = try #require(published.lease?.generation)
    await registry.deliverSurface(paneId: result.paneId, published: published, sequence: generation)
    await registry.deliverSurface(to: token, published: published, sequence: generation)

    // No send happened during the parked drain: the fence held.
    #expect(sends.value == 0)
    #expect(await registry.hasEntry(paneId: result.paneId, connectionId: 1) == false)

    backend.drainRelease.signal()
    await closing.value
    #expect(sends.value == 0)
    withExtendedLifetime(stream) {}
}
