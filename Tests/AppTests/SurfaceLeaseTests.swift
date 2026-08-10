// SPDX-License-Identifier: GPL-3.0-or-later
//
// SurfaceLease + SurfaceReleaseAccountant: the GUI half of the lease
// loop. These pin: a leased surface bumps/decrements the use count and
// signals release exactly once by ARC; an unleased surface does neither;
// and the accountant's cumulative watermark is `min(held)` (or one past
// the highest received when empty).

@testable import App
import DaemonProtocol
import Foundation
import IOSurface
import Testing

private func makeSurface() -> IOSurfaceRef {
    let props: [String: Any] = [
        kIOSurfaceWidth as String: 4,
        kIOSurfaceHeight as String: 4,
        kIOSurfaceBytesPerElement as String: 4,
        kIOSurfacePixelFormat as String: 0x42_47_52_41
    ]
    // Force-unwrap is fine in a test fixture; a nil here fails the test
    // loudly rather than masking a real allocation failure.
    // swiftlint:disable:next force_unwrapping
    return IOSurfaceCreate(props as CFDictionary)!
}

/// `@unchecked Sendable`: `count` is read/written only under `lock`.
private final class ReleaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func bump() { lock.lock(); count += 1; lock.unlock() }
}

@Test
func leasedSurfaceBumpsUseCountAndReleasesOnceOnDeinit() {
    let surface = makeSurface()
    let before = IOSurfaceGetUseCount(surface)
    let counter = ReleaseCounter()
    do {
        let lease = SurfaceLease(
            surface: surface,
            paneId: "p1",
            subscriptionToken: UUID(),
            leaseEpoch: 1,
            generation: 5,
            onRelease: { _ in counter.bump() }
        )
        #expect(IOSurfaceGetUseCount(surface) == before + 1)
        withExtendedLifetime(lease) {}
    }
    // Deinit decremented the use count and signalled release exactly once.
    #expect(IOSurfaceGetUseCount(surface) == before)
    #expect(counter.value == 1)
}

@Test
func unleasedSurfaceTakesNoUseCountAndNeverReleases() {
    let surface = makeSurface()
    let before = IOSurfaceGetUseCount(surface)
    let counter = ReleaseCounter()
    do {
        let lease = SurfaceLease(
            surface: surface,
            paneId: "p1",
            subscriptionToken: UUID(),
            leaseEpoch: 0,
            generation: 0,
            onRelease: nil
        )
        #expect(IOSurfaceGetUseCount(surface) == before)
        withExtendedLifetime(lease) {}
    }
    #expect(IOSurfaceGetUseCount(surface) == before)
    #expect(counter.value == 0)
}

/// `@unchecked Sendable`: `params` is read/written only under `lock`.
private final class ReleaseSink: @unchecked Sendable {
    private let lock = NSLock()
    private var params: [SurfaceReleaseParams] = []
    var last: SurfaceReleaseParams? { lock.lock(); defer { lock.unlock() }; return params.last }
    var lowestHelds: [UInt64] { lock.lock(); defer { lock.unlock() }; return params.map(\.lowestHeld) }
    func record(_ value: SurfaceReleaseParams) {
        lock.lock(); params.append(value); lock.unlock()
    }
}

private func settleTicks() async {
    try? await Task.sleep(nanoseconds: 40_000_000)
}

@Test
func accountantWatermarkIsMinOfHeldSet() async {
    let sink = ReleaseSink()
    let accountant = SurfaceReleaseAccountant { params in sink.record(params) }
    let token = UUID()
    for generation: UInt64 in [1, 2, 3] {
        await accountant.acquire(paneId: "p1", subscriptionToken: token, leaseEpoch: 7, generation: generation)
    }
    // Release the lowest, and the watermark rises to the new min.
    await accountant.release(paneId: "p1", subscriptionToken: token, leaseEpoch: 7, generation: 1)
    await settleTicks()
    #expect(sink.last?.lowestHeld == 2)
    #expect(sink.last?.subscriptionToken == token.uuidString)
    #expect(sink.last?.leaseEpoch == 7)

    await accountant.stop()
}

@Test
func accountantEmptySetWatermarkIsPastHighestReceived() async {
    let sink = ReleaseSink()
    let accountant = SurfaceReleaseAccountant { params in sink.record(params) }
    let token = UUID()
    for generation: UInt64 in [10, 11] {
        await accountant.acquire(paneId: "p1", subscriptionToken: token, leaseEpoch: 1, generation: generation)
    }
    await accountant.release(paneId: "p1", subscriptionToken: token, leaseEpoch: 1, generation: 10)
    await accountant.release(paneId: "p1", subscriptionToken: token, leaseEpoch: 1, generation: 11)
    await settleTicks()
    // Empty held set ⇒ one past the highest received (11) ⇒ 12.
    #expect(sink.last?.lowestHeld == 12)

    await accountant.stop()
}
