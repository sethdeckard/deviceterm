// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import IOSurface
import Testing

// `SimDeviceBackend` takes concrete bridge handles, so the frame pump is
// driven here directly. That reaches the part a live sim cannot exercise on
// demand: what happens when the consumer stops acknowledging frames and the
// pool runs out of slots.

/// Collects what the pump published, and optionally keeps every frame so the
/// pool stays exhausted the way an unacking consumer would leave it.
///
/// `@unchecked Sendable`: every access goes through `lock`.
private final class PublishSink: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [PublishedSurface] = []
    private var failures: [String] = []
    private var published = 0
    private let retaining: Bool

    /// Every frame the pump handed over, whether or not it is still retained.
    var count: Int { lock.withLock { published } }
    var failure: String? { lock.withLock { failures.first } }
    var leases: [LeaseMetadata] { lock.withLock { frames.compactMap(\.lease) } }
    var surfaceIDs: [IOSurfaceID] {
        lock.withLock { frames.map { frame in frame.surface.withRef { IOSurfaceGetID($0) } } }
    }

    init(retaining: Bool) { self.retaining = retaining }

    func publish(_ frame: PublishedSurface) {
        lock.withLock {
            published += 1
            frames.append(frame)
            // A draining consumer drops each frame once it has it, which
            // releases the slot's hold. Retaining is what an unacking one does.
            if !retaining, frames.count > 1 { frames.removeFirst() }
        }
    }

    func fail(_ reason: String) {
        lock.withLock { failures.append(reason) }
    }
}

private func makeSourceStream(
    frames: Int,
    width: Int = 32,
    height: Int = 32
) -> AsyncStream<RetainedSurface> {
    let (stream, continuation) = AsyncStream.makeStream(of: RetainedSurface.self)
    for _ in 0..<frames {
        guard let surface = SurfaceCopy.makeSurface(width: width, height: height) else { continue }
        continuation.yield(RetainedSurface(surface))
    }
    continuation.finish()
    return stream
}

@Test
func aPumpedSimFrameCarriesALeaseAndCopiesOffTheSource() async throws {
    let pool = LeasedSurfacePool(slotCount: 6)
    let sink = PublishSink(retaining: true)
    let source = try #require(SurfaceCopy.makeSurface(width: 32, height: 32))
    let sourceID = IOSurfaceGetID(source)
    let (stream, continuation) = AsyncStream.makeStream(of: RetainedSurface.self)
    continuation.yield(RetainedSurface(source))
    continuation.finish()

    await SimDeviceBackend.pumpFrames(
        surfaces: stream,
        pool: pool,
        recoveryThreshold: 120,
        publish: sink.publish,
        fail: sink.fail
    )

    #expect(sink.count == 1)
    // The lease is what puts a sim frame on the acknowledged delivery path.
    #expect(sink.leases.count == 1)
    // Published from a pool slot, not the surface CoreSimulator keeps writing.
    #expect(sink.surfaceIDs.first != sourceID)
    #expect(sink.failure == nil)
}

@Test
func anUnackedSimStreamRecoversOnceThenFailsThePane() async throws {
    // A consumer that stops acking holds every slot. The pump drops rather
    // than blocking, attempts one controlled recovery, and fails the pane on
    // the second bout instead of growing the daemon without bound.
    let pool = LeasedSurfacePool(slotCount: 3)
    let sink = PublishSink(retaining: true)

    await SimDeviceBackend.pumpFrames(
        surfaces: makeSourceStream(frames: 40),
        pool: pool,
        recoveryThreshold: 2,
        publish: sink.publish,
        fail: sink.fail
    )

    let failure = try #require(sink.failure)
    #expect(failure.contains("surface pool stayed unavailable"))
    // It published what the pool could give before giving up, rather than
    // failing on the first drop.
    #expect(sink.count >= 1)
}

@Test
func aDrainingConsumerKeepsTheSimStreamPublishing() async {
    // The same pump with a consumer that releases each frame: every one of
    // them publishes, and nothing fails.
    let pool = LeasedSurfacePool(slotCount: 3)
    let sink = PublishSink(retaining: false)

    await SimDeviceBackend.pumpFrames(
        surfaces: makeSourceStream(frames: 40),
        pool: pool,
        recoveryThreshold: 2,
        publish: sink.publish,
        fail: sink.fail
    )

    #expect(sink.failure == nil)
    // Every frame got through: a pool of 3 sustains an unbounded stream as
    // long as its slots come back.
    #expect(sink.count == 40)
}
