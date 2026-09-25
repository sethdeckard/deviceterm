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

    var readTimes: [ContinuousClock.Instant] { queue.sync { attempts } }
    var sleepCount: Int { queue.sync { sleeps } }
    var failureMessage: String? { queue.sync { failure } }
    var published: [PublishedSurface] { queue.sync { frames } }
    var sourceID: IOSurfaceID { queue.sync { source.withRef { IOSurfaceGetID($0) } } }

    init(retaining: Bool = false, readLimit: Int = 1) throws {
        self.retaining = retaining
        self.readLimit = readLimit
        pool = LeasedSurfacePool(slotCount: 3)
        source = RetainedSurface(try #require(SurfaceCopy.makeSurface(width: 32, height: 32)))
    }

    func run() async {
        signal.notify()
        await SimFramePump(
            signal: signal,
            pool: pool,
            timing: .init(
                now: { self.queue.sync { self.instant } },
                sleep: { deadline in
                    self.queue.sync {
                        self.sleeps += 1
                        self.instant = deadline
                        if let replacement = self.replaceDuringSleep { self.source = replacement }
                    }
                    // Multiple callbacks during the wait still mean one read.
                    for _ in 0..<1_000 { self.signal.notify() }
                }
            ),
            read: {
                self.queue.sync {
                    self.attempts.append(self.instant)
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
