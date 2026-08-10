// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

// IdleMonitor tests use an injected clock to advance time without
// real `Task.sleep` and the public `tick()` method to run a poll
// synchronously. The real `runLoop()` (with `Task.sleep`) is
// covered indirectly: if `tick()` is right, the loop is right.

private actor BoolBox {
    private(set) var value: Bool
    init(_ value: Bool) { self.value = value }
    func set(_ value: Bool) { self.value = value }
}

private actor IntBox {
    private(set) var count: Int = 0
    func increment() { count += 1 }
}

/// Thread-safe synthetic clock for IdleMonitor tests. The
/// `IdleMonitor.clock` closure is `@Sendable () -> Date` (sync),
/// so we need a synchronous reader. `NSLock`-backed storage is
/// sufficient for serialized test access; production code uses the
/// default `Date()` clock.
private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(start: Date) { self.current = start }
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

@Test
func idleMonitorStaysAliveWhileBusy() async {
    let busy = BoolBox(true)
    let terminated = IntBox()
    let monitor = IdleMonitor(
        idleTimeoutSeconds: 60,
        isBusy: { await busy.value },
        terminate: { await terminated.increment() }
    )
    for _ in 0..<5 {
        await monitor.tick()
    }
    let calls = await terminated.count
    #expect(calls == 0)
    let didTerminate = await monitor.didTerminate
    #expect(didTerminate == false)
}

@Test
func idleMonitorTerminatesAfterTimeout() async {
    let busy = BoolBox(false)
    let terminated = IntBox()
    let origin = Date(timeIntervalSince1970: 1_000_000)
    let clockBox = ClockBox(start: origin)
    let monitor = IdleMonitor(
        idleTimeoutSeconds: 5,
        clock: { @Sendable in clockBox.now() },
        isBusy: { await busy.value },
        terminate: { await terminated.increment() }
    )
    // First tick at t=origin: lastBusyTime ≈ origin, idle = 0,
    // below timeout. No terminate yet.
    await monitor.tick()
    var calls = await terminated.count
    #expect(calls == 0)

    // Advance clock past timeout, then tick.
    clockBox.advance(by: 6)
    await monitor.tick()
    calls = await terminated.count
    #expect(calls == 1)
    let didTerminate = await monitor.didTerminate
    #expect(didTerminate == true)
}

@Test
func idleMonitorLatchesTerminateAcrossTicks() async {
    // After terminate fires, subsequent ticks must NOT re-call it.
    let busy = BoolBox(false)
    let terminated = IntBox()
    let origin = Date(timeIntervalSince1970: 1_000_000)
    let clockBox = ClockBox(start: origin)
    let monitor = IdleMonitor(
        idleTimeoutSeconds: 1,
        clock: { @Sendable in clockBox.now() },
        isBusy: { await busy.value },
        terminate: { await terminated.increment() }
    )
    clockBox.advance(by: 2)
    await monitor.tick()
    await monitor.tick()
    await monitor.tick()
    let calls = await terminated.count
    #expect(calls == 1)
}

@Test
func idleMonitorResetsBusyTimeOnBusyPoll() async {
    // Busy tick must reset the idle window: a brief lull followed
    // by activity should not count toward the timeout.
    let busy = BoolBox(true)
    let terminated = IntBox()
    let origin = Date(timeIntervalSince1970: 1_000_000)
    let clockBox = ClockBox(start: origin)
    let monitor = IdleMonitor(
        idleTimeoutSeconds: 5,
        clock: { @Sendable in clockBox.now() },
        isBusy: { await busy.value },
        terminate: { await terminated.increment() }
    )
    // 10s pass while busy, so it must not terminate.
    clockBox.advance(by: 10)
    await monitor.tick()
    var calls = await terminated.count
    #expect(calls == 0)
    // Flip to idle. The just-completed busy tick reset
    // lastBusyTime, so a full timeout must pass after the flip.
    await busy.set(false)
    clockBox.advance(by: 3)
    await monitor.tick()
    calls = await terminated.count
    #expect(calls == 0)
    clockBox.advance(by: 3)
    await monitor.tick()
    calls = await terminated.count
    #expect(calls == 1)
}

@Test
func idleSecondsReflectsClockDelta() async {
    let busy = BoolBox(true)
    let origin = Date(timeIntervalSince1970: 1_000_000)
    let clockBox = ClockBox(start: origin)
    let monitor = IdleMonitor(
        idleTimeoutSeconds: 60,
        clock: { @Sendable in clockBox.now() },
        isBusy: { await busy.value },
        terminate: {}
    )
    // Busy tick resets lastBusyTime to now.
    await monitor.tick()
    // Advance clock 7s; idleSeconds should report ~7.
    clockBox.advance(by: 7)
    let idle = await monitor.idleSeconds
    #expect(idle >= 6.5 && idle <= 7.5)
}
