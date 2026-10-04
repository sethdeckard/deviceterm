// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import IOSurface
import Testing

/// Virtual time and a source that can change while the pump waits.
/// All mutable state is serialized by `queue`.
private final class PumpHarness: @unchecked Sendable {
    let signal = SimFrameSignal()
    let pool: LeasedSurfacePool
    private let queue = DispatchQueue(label: "test.sim-pump")
    private var instant = ContinuousClock.now
    private var attempts: [ContinuousClock.Instant] = []
    private var frames: [PublishedSurface] = []
    private var failure: String?
    private var sleeps = 0
    private var source: RetainedSurface
    private let retaining: Bool
    private let readLimit: Int
    var replaceDuringSleep: RetainedSurface?
    /// How long past its deadline every sleep wakes.
    var wakeLate: Duration = .zero
    /// How long every surface read takes.
    var readDelay: Duration = .zero

    var readTimes: [ContinuousClock.Instant] { queue.sync { attempts } }
    var sleepCount: Int { queue.sync { sleeps } }
    var failureMessage: String? { queue.sync { failure } }
    var published: [PublishedSurface] { queue.sync { frames } }
    var sourceID: IOSurfaceID { queue.sync { source.withRef { IOSurfaceGetID($0) } } }

    let instrumentation: SimFramePump.Instrumentation?
    let blitter: SurfaceBlitter?

    init(
        retaining: Bool = false,
        readLimit: Int = 1,
        pool: LeasedSurfacePool = LeasedSurfacePool(slotCount: 3),
        blitter: SurfaceBlitter? = nil,
        instrumentation: SimFramePump.Instrumentation? = nil
    ) throws {
        self.retaining = retaining
        self.readLimit = readLimit
        self.pool = pool
        self.blitter = blitter
        self.instrumentation = instrumentation
        source = RetainedSurface(try #require(SurfaceCopy.makeSurface(width: 32, height: 32)))
    }

    func withSource<T>(_ body: (IOSurfaceRef) -> T) -> T { queue.sync { source.withRef(body) } }

    func run() async {
        signal.notify()
        await SimFramePump(
            signal: signal,
            pool: pool,
            copyQueue: BlockingWorkQueue(label: "test.sim-pump.copy", qos: .userInteractive),
            blitter: blitter,
            timing: .init(
                now: { self.queue.sync { self.instant } },
                sleep: { deadline in
                    self.queue.sync {
                        self.sleeps += 1
                        self.instant = deadline.advanced(by: self.wakeLate)
                        if let replacement = self.replaceDuringSleep { self.source = replacement }
                    }
                    // Multiple callbacks during the wait still mean one read.
                    for _ in 0..<1_000 { self.signal.notify() }
                }
            ),
            instrumentation: instrumentation,
            read: {
                self.queue.sync {
                    self.attempts.append(self.instant)
                    self.instant = self.instant.advanced(by: self.readDelay)
                    if self.attempts.count >= self.readLimit {
                        self.signal.finish()
                    } else {
                        self.signal.notify()
                    }
                    return self.source
                }
            },
            publish: { frame in
                self.queue.sync {
                    if !self.retaining { self.frames.removeAll() }
                    self.frames.append(frame)
                }
            },
            fail: { reason in self.queue.sync { self.failure = reason } }
        ).run()
    }
}

@Test
func aPumpedSimFrameCarriesALeaseAndCopiesOffTheSource() async throws {
    let harness = try PumpHarness()
    await harness.run()
    let frame = try #require(harness.published.first)
    #expect(frame.lease != nil)
    #expect(frame.surface.withRef { IOSurfaceGetID($0) } != harness.sourceID)
    #expect(harness.sleepCount == 0)
    #expect(harness.failureMessage == nil)
}

@Test("a pumped frame holds the source's pixels, copied on the CPU or blitted", arguments: [false, true])
func aPumpedSimFrameHoldsTheSourcePixels(blitting: Bool) async throws {
    let blitter = blitting ? SurfaceBlitter(cacheCapacity: 4) : nil
    if blitting, blitter == nil { return }
    let harness = try PumpHarness(blitter: blitter)
    let expected = harness.withSource { surface in
        IOSurfaceLock(surface, [], nil)
        defer { IOSurfaceUnlock(surface, [], nil) }
        let count = IOSurfaceGetBytesPerRow(surface) * IOSurfaceGetHeight(surface)
        let bytes = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        for index in 0..<count { bytes[index] = UInt8(truncatingIfNeeded: index * 31 + 7) }
        return Array(UnsafeBufferPointer(start: bytes, count: count))
    }
    await harness.run()
    let frame = try #require(harness.published.first)
    let copied = frame.surface.withRef { surface in
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let bytes = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: expected.count))
    }
    #expect(copied == expected)
}

@Test
func simulatorCopiesArePacedAndReadTheNewestSurface() async throws {
    let harness = try PumpHarness(readLimit: 2)
    harness.replaceDuringSleep = RetainedSurface(
        try #require(SurfaceCopy.makeSurface(width: 64, height: 64))
    )
    await harness.run()
    #expect(harness.readTimes.count == 2)
    #expect(harness.readTimes[1] - harness.readTimes[0] == .nanoseconds(16_666_667))
    #expect(harness.sleepCount == 1)
    let frame = try #require(harness.published.last)
    #expect(frame.surface.withRef { IOSurfaceGetWidth($0) } == 64)
}

@Test("a sleep that wakes late doesn't stretch every later period")
func lateWakesKeepTheCadenceAnchored() async throws {
    let harness = try PumpHarness(readLimit: 11)
    harness.wakeLate = .milliseconds(4)
    await harness.run()
    let times = harness.readTimes
    #expect(times.count == 11)
    // The first sleep lands 4 ms late; every later one is due one interval after
    // the previous deadline, so the lateness never accumulates.
    #expect(times[10] - times[1] == .nanoseconds(16_666_667) * 9)
}

@Test("a read slower than an interval still leaves half an interval before the next read")
func slowResolvesDoNotCopyBackToBack() async throws {
    let harness = try PumpHarness(readLimit: 6)
    harness.readDelay = .milliseconds(20)
    await harness.run()
    let times = harness.readTimes
    #expect(times.count == 6)
    for (earlier, later) in zip(times, times.dropFirst()) {
        // Each read ends 20 ms after it starts, and the next waits half an
        // interval past that.
        #expect(later - earlier >= .milliseconds(20) + .nanoseconds(16_666_667) / 2)
    }
}

@Test("a slow resolve pushes the deadline out; a normal one leaves it", arguments: [
    (deadline: 16, resolvedAt: 1, expected: 16),
    (deadline: 16, resolvedAt: 8, expected: 16),
    (deadline: 16, resolvedAt: 9, expected: 17),
    (deadline: 16, resolvedAt: 20, expected: 28)
])
func resolveFloorsTheDeadline(deadline: Int, resolvedAt: Int, expected: Int) {
    let origin = ContinuousClock.now
    let instant = { (milliseconds: Int) in origin.advanced(by: .milliseconds(milliseconds)) }
    let result = SimFramePump.deadline(
        instant(deadline),
        afterResolvingAt: instant(resolvedAt),
        interval: .milliseconds(16)
    )
    #expect(result == instant(expected))
}

@Test("the next deadline anchors to the last one while the pump keeps pace", arguments: [
    (previous: nil as Int?, now: 0, expected: 16),
    (previous: 0 as Int?, now: 4, expected: 16),
    (previous: 0 as Int?, now: 7, expected: 16),
    (previous: 0 as Int?, now: 9, expected: 25),
    (previous: 0 as Int?, now: 500, expected: 516)
])
func nextDeadlineAnchorsOrRestarts(previous: Int?, now: Int, expected: Int) {
    let origin = ContinuousClock.now
    let instant = { (milliseconds: Int) in origin.advanced(by: .milliseconds(milliseconds)) }
    let deadline = SimFramePump.nextDeadline(
        after: previous.map(instant),
        now: instant(now),
        interval: .milliseconds(16)
    )
    #expect(deadline == instant(expected))
}

@Test
func anUnackedSimStreamRecoversOnceThenFailsThePane() async throws {
    let harness = try PumpHarness(retaining: true, readLimit: 400)
    await harness.run()
    #expect(harness.failureMessage?.contains("surface pool stayed unavailable") == true)
    #expect(harness.published.count >= 1)
    #expect(harness.readTimes.count < 400)
    let times = harness.readTimes
    #expect(try #require(times.last) - #require(times.first) >= .seconds(4))
}

@Test
func aPausedSimPoolKeepsOnlyItsCurrentFrameAndResumes() async throws {
    // The lane runs a fresh pump per resume against the same pool.
    let pool = LeasedSurfacePool(slotCount: 3)
    let before = try PumpHarness(readLimit: 3, pool: pool)
    await before.run()
    #expect(before.published.count == 1)

    await pool.setIdle(true, serial: 1)
    // The harness still holds its last frame, as the pane's current surface.
    // Earlier frames' releases reach the pool asynchronously and are freed as
    // they land.
    var allocated = await pool.allocatedSlotCount()
    for _ in 0..<200 where allocated != 1 {
        try? await Task.sleep(nanoseconds: 500_000)
        allocated = await pool.allocatedSlotCount()
    }
    #expect(allocated == 1)

    await pool.setIdle(false, serial: 2)
    let after = try PumpHarness(readLimit: 2, pool: pool)
    await after.run()
    #expect(after.published.count == 1)
    #expect(after.failureMessage == nil)
    #expect(await pool.snapshotCounters().exhaustionDrops == 0)
    _ = before
}

@Test
func simulatorSignalsCoalesceAndRetiredSignalsCannotWake() {
    let signal = SimFrameSignal()
    for _ in 0..<10_000 { signal.notify() }
    #expect(signal.consume() != nil)
    #expect(signal.consume() == nil)
    signal.notify()
    signal.finish()
    signal.notify()
    #expect(signal.consume() == nil)
}

@Test
func simulatorPumpCancellationDoesNotReadOrCopy() async {
    let signal = SimFrameSignal()
    let task = Task {
        await SimFramePump(
            signal: signal,
            pool: LeasedSurfacePool(slotCount: 3),
            copyQueue: BlockingWorkQueue(label: "test.sim-pump.copy"),
            read: { Issue.record("cancelled pump read a surface"); return nil },
            publish: { _ in Issue.record("cancelled pump published") },
            fail: { _ in Issue.record("cancelled pump failed") }
        ).run()
    }
    task.cancel()
    await task.value
}

@Test
func aDrainingConsumerKeepsTheSimStreamPublishing() async throws {
    let harness = try PumpHarness(readLimit: 40)
    await harness.run()
    #expect(harness.readTimes.count == 40)
    #expect(harness.failureMessage == nil)
}

// MARK: - Frame metrics

/// A nanosecond clock that advances a fixed step on every read, so a run of
/// frames crosses metrics windows deterministically.
private final class SteppingClock: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.sim-pump.clock")
    private var value: UInt64 = 0
    private let step: UInt64

    init(step: UInt64) { self.step = step }

    func next() -> UInt64 {
        queue.sync {
            value += step
            return value
        }
    }
}

/// An armed sink writing to a fresh file, and a way to read its rows back.
private struct MetricsCapture {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("sim-pump-metrics-\(UUID().uuidString)").path
    let deviceId = "sim"
    let sink: FrameMetricsSink

    init() throws {
        let made = FrameMetricsSink.make(baseDirectory: base, deviceId: deviceId, log: nil)
        sink = try #require(made)
    }

    func instrumentation(step: UInt64 = 100_000_000) -> SimFramePump.Instrumentation {
        let clock = SteppingClock(step: step)
        return SimFramePump.Instrumentation(sink: sink, now: { clock.next() })
    }

    func rows() throws -> [FrameMetricsSummary] {
        sink.drain()
        let path = "\(base).\(deviceId).frames.jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        return try contents.split(separator: "\n").map {
            try JSONDecoder().decode(FrameMetricsSummary.self, from: Data($0.utf8))
        }
    }
}

@Test
func anInstrumentedSimPumpRecordsWindowsThatAccountForEveryFrame() async throws {
    let capture = try MetricsCapture()
    let harness = try PumpHarness(readLimit: 12, instrumentation: capture.instrumentation())
    await harness.run()
    let rows = try capture.rows()
    #expect(!rows.isEmpty)
    for row in rows {
        #expect(row.framesConsumed == row.framesPublished + row.framesDroppedNoSurface + row.framesDroppedExhaustion)
        #expect(row.copy.sampleCount == UInt64(row.framesPublished))
        #expect((row.copyCPU?.sampleCount ?? 0) == UInt64(row.framesPublished))
        #expect(row.bytesMoved > 0)
        #expect(row.sourceWidth == 32 && row.contentWidth == 32)
        #expect(row.pixelFormat == "BGRA")
        #expect(row.poolSlotsAllocated >= 1)
        #expect(row.poolSlotsHighWater >= row.poolSlotsAllocated)
    }
}

@Test
func aBlittingSimPumpRecordsCopyCPUForEveryFrame() async throws {
    guard let blitter = SurfaceBlitter(cacheCapacity: 4) else { return }
    let capture = try MetricsCapture()
    let harness = try PumpHarness(readLimit: 12, blitter: blitter, instrumentation: capture.instrumentation())
    await harness.run()
    let rows = try capture.rows()
    #expect(!rows.isEmpty)
    for row in rows {
        #expect(row.framesPublished > 0)
        #expect(row.copyCPU?.sampleCount == UInt64(row.framesPublished))
        #expect(row.bytesMoved > 0)
    }
}

@Test
func anInstrumentedSimPumpCountsExhaustionDrops() async throws {
    let capture = try MetricsCapture()
    let harness = try PumpHarness(retaining: true, readLimit: 400, instrumentation: capture.instrumentation())
    await harness.run()
    let rows = try capture.rows()
    #expect(rows.contains { $0.framesDroppedExhaustion > 0 })
    #expect(rows.contains { $0.poolSlotsAllocated == 3 && $0.poolSlotsFree == 0 })
}

@Test
func aSimPumpThatCapturesOnceWritesNoRow() async throws {
    // The window only closes on a later update, so a pane that goes quiet
    // after one frame keeps no timer and writes nothing.
    let capture = try MetricsCapture()
    let harness = try PumpHarness(readLimit: 1, instrumentation: capture.instrumentation(step: 10_000_000_000))
    await harness.run()
    #expect(harness.published.count == 1)
    capture.sink.drain()
    let path = "\(capture.base).\(capture.deviceId).frames.jsonl"
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(try String(contentsOfFile: path, encoding: .utf8).isEmpty)
}

@Test
func holdAgesAckedWhilePausedStayOutOfTheFirstRowAfterResume() async throws {
    let pool = LeasedSurfacePool(slotCount: 3, recordHoldAges: true)
    let before = try PumpHarness(readLimit: 3, pool: pool, instrumentation: try MetricsCapture().instrumentation())
    await before.run()

    // While paused, the GUI acknowledges a hold, which the pool times.
    let token = UUID()
    await pool.registerToken(token, connectionId: 1)
    let published = try #require(await pool.acquire(width: 32, height: 32))
    let lease = try #require(published.lease)
    let grant = try #require(await lease.acquireHold(token))
    #expect(await grant.commit())
    await pool.applyWatermark(token: token, epoch: lease.epoch, lowestHeld: lease.generation + 1, connectionId: 1)

    let capture = try MetricsCapture()
    let after = try PumpHarness(readLimit: 12, pool: pool, instrumentation: capture.instrumentation())
    await after.run()
    let first = try #require(try capture.rows().first)
    #expect(first.leaseHold.sampleCount == 0)
    _ = (before, published)
}
