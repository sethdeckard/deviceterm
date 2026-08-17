// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// A paced gesture's behaviour when it runs behind schedule, exercised against a
// virtual clock so nothing here waits on real time.

/// A pacer whose clock only moves when a sleep asks it to, plus an optional
/// per-sleep overshoot so a test can put a gesture arbitrarily far behind.
///
/// Serial-queue isolated rather than a bare mutable box: a gesture reads and
/// advances the instant from whichever task it happens to be running on, and
/// `@unchecked Sendable` without the queue would be a data race the tests
/// themselves introduced.
final class FakeGesturePacer: GesturePacing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.deviceterm.tests.gesture-pacer")
    private let origin = ContinuousClock.now
    private var offset: Duration = .zero
    private var overshoots: [Duration]
    private var sleeps = 0
    private var requested: [Duration] = []

    var sleepCount: Int {
        queue.sync { sleeps }
    }

    /// Every deadline a sleep was asked for, as an offset from the pacer's
    /// origin. A loop that sleeps before each send makes this the send
    /// schedule, which is what the timing assertions are actually about.
    var requestedOffsets: [Duration] {
        queue.sync { requested }
    }

    /// How far the virtual clock has moved, including any injected overshoot.
    var elapsed: Duration {
        queue.sync { offset }
    }

    /// `overshoots` is consumed one entry per sleep; once exhausted, every
    /// later sleep lands exactly on its deadline.
    init(overshoots: [Duration] = []) {
        self.overshoots = overshoots
    }

    func now() -> ContinuousClock.Instant {
        queue.sync { origin + offset }
    }

    // The protocol requires `async`; this conformer never suspends.
    // swiftlint:disable:next async_without_await
    func sleep(until deadline: ContinuousClock.Instant) async {
        queue.sync {
            sleeps += 1
            requested.append(deadline - origin)
            let overshoot = overshoots.isEmpty ? .zero : overshoots.removeFirst()
            let target = max(origin + offset, deadline) + overshoot
            offset = target - origin
        }
    }
}

@Test
func checkpointProceedsWhileCurrentAndUncancelled() {
    let backend = MockDeviceBackend()
    #expect(SimInputSynthesis.checkpoint(backend: backend, generation: 0) == .proceed)
}

@Test
func checkpointReleasesWhenCancelled() async {
    let backend = MockDeviceBackend()
    // The child parks far longer than the test could take, so `cancelAll` is
    // what ends it whether or not it had started running.
    let decision = await withTaskGroup(of: SimInputSynthesis.PacedStep.self) { group in
        group.addTask {
            try? await Task.sleep(for: .seconds(3_600))
            return SimInputSynthesis.checkpoint(backend: backend, generation: 0)
        }
        group.cancelAll()
        return await group.next()
    }
    #expect(decision == .releaseAndStop)
}

@Test
func checkpointSendsNothingWhenGenerationWentStale() {
    let backend = MockDeviceBackend()
    backend.inputGenerationCurrent = false
    // Staleness dominates: quiesce owns the release, so the loop must not add
    // one of its own even though it is also holding contact.
    #expect(SimInputSynthesis.checkpoint(backend: backend, generation: 0) == .stopWithoutSend)
}

@Test
func aCancelledLongPressStillReleasesItsContact() async {
    let backend = MockDeviceBackend()
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            try? await SimInputSynthesis.longPress(
                backend: backend,
                paneId: UUID(),
                generation: 0,
                x: 0.5,
                y: 0.5,
                durationMs: 60_000
            )
        }
        group.cancelAll()
        await group.waitForAll()
    }
    #expect(backend.tapDownPoints.count == 1)
    #expect(backend.tapUpPoints.count == 1)
}

@Test
func aLongPressWhoseGenerationWentStaleSendsNoRelease() async throws {
    let backend = MockDeviceBackend()
    backend.inputGenerationCurrent = false
    try await SimInputSynthesis.longPress(
        backend: backend,
        paneId: UUID(),
        generation: 0,
        x: 0.5,
        y: 0.5,
        durationMs: 200,
        pacer: FakeGesturePacer()
    )
    #expect(backend.tapDownPoints.count == 1)
    #expect(backend.tapUpPoints.isEmpty)
}

@Test
func aLongPressHoldsForItsRequestedDurationAndNoLonger() async throws {
    let backend = MockDeviceBackend()
    let pacer = FakeGesturePacer()
    try await SimInputSynthesis.longPress(
        backend: backend,
        paneId: UUID(),
        generation: 0,
        x: 0.5,
        y: 0.5,
        durationMs: 200,
        pacer: pacer
    )
    // Six 33ms chunks and a 2ms remainder, the last bounded by the hold's
    // deadline rather than running a full chunk past it.
    #expect(pacer.requestedOffsets.last == .milliseconds(200))
    #expect(pacer.sleepCount == 7)
    #expect(pacer.elapsed == .milliseconds(200))
    #expect(backend.tapUpPoints.count == 1)
}

@Test
func aLateSwipeSkipsSamplesInsteadOfReplayingThem() async throws {
    let backend = MockDeviceBackend()
    // 160ms over 16ms frames is ten samples. The first sleep lands three
    // frames late, so samples 1 through 3 are never sent.
    let pacer = FakeGesturePacer(overshoots: [.milliseconds(48)])
    let outcome = try await SimInputSynthesis.swipe(
        backend: backend,
        paneId: UUID(),
        generation: 0,
        fromX: 0,
        fromY: 0,
        toX: 1,
        toY: 0,
        durationMs: 160,
        pacer: pacer
    )
    // One opening contact plus the seven samples that were still due.
    #expect(backend.tapDownPoints.count == 8)
    #expect(outcome.steps == 7)
    // The skipped samples are dropped, not replayed: the first sample sent is
    // the one that was due when the loop woke, not sample 1.
    #expect(backend.tapDownPoints[1].x == 0.4)
    // The final sample is never skipped, so the gesture still lands on its
    // endpoint before the lift.
    #expect(backend.tapDownPoints.last?.x == 1.0)
    #expect(backend.tapUpPoints.count == 1)
}

@Test
func anOnScheduleSwipeSendsEverySample() async throws {
    let backend = MockDeviceBackend()
    let outcome = try await SimInputSynthesis.swipe(
        backend: backend,
        paneId: UUID(),
        generation: 0,
        fromX: 0,
        fromY: 0,
        toX: 1,
        toY: 0,
        durationMs: 160,
        pacer: FakeGesturePacer()
    )
    #expect(outcome.steps == 10)
    #expect(backend.tapDownPoints.count == 11)
}

@Test
func aSwipePreemptedBeforeItsFirstSampleReportsATap() async throws {
    let backend = MockDeviceBackend()
    backend.inputGenerationCurrent = false
    let outcome = try await SimInputSynthesis.swipe(
        backend: backend,
        paneId: UUID(),
        generation: 0,
        fromX: 0,
        fromY: 0,
        toX: 1,
        toY: 0,
        durationMs: 160,
        pacer: FakeGesturePacer()
    )
    // Nothing interpolated went out, so the ack must not claim a drag.
    #expect(outcome.steps == 0)
    #expect(SwipeAck(steps: outcome.steps, durationMs: outcome.durationMs).dispatched == .tap)
    // The scheduled duration is still reported: it says what was planned, not
    // how long the gesture actually ran.
    #expect(outcome.durationMs == 160)
}

@Test
func aLateDwellSkipsResendsInsteadOfFiringThemBackToBack() async throws {
    let backend = MockDeviceBackend()
    // A 99ms hold is three dwell frames at the 33ms cadence. The swipe's own
    // single interpolation sleep runs on time, then the first dwell wake lands
    // two frames late, so only the frame due then is resent.
    let pacer = FakeGesturePacer(overshoots: [.zero, .milliseconds(66)])
    _ = try await SimInputSynthesis.swipe(
        backend: backend,
        paneId: UUID(),
        generation: 0,
        fromX: 0,
        fromY: 0,
        toX: 1,
        toY: 0,
        durationMs: 16,
        holdMs: 99,
        pacer: pacer
    )
    // Opening contact, one interpolated sample, and one dwell resend rather
    // than three.
    #expect(backend.tapDownPoints.count == 3)
}

@Test
func aDwellHoldsForAtLeastTheRequestedTime() async throws {
    let backend = MockDeviceBackend()
    let pacer = FakeGesturePacer()
    // 50ms is not a multiple of the 33ms report cadence. Flooring the frame
    // count would lift after one frame, cutting the requested hold to 33ms.
    _ = try await SimInputSynthesis.swipe(
        backend: backend,
        paneId: UUID(),
        generation: 0,
        fromX: 0,
        fromY: 0,
        toX: 1,
        toY: 0,
        durationMs: 16,
        holdMs: 50,
        pacer: pacer
    )
    // One interpolation sleep to 16ms, then the dwell anchored there: a frame
    // at the cadence and a shorter final frame landing on the hold's end
    // rather than past it, so the hold spans the full 50ms it asked for.
    #expect(pacer.requestedOffsets == [.milliseconds(16), .milliseconds(49), .milliseconds(66)])
}

@Test
func consecutiveDwellResendsAreNeverTheSamePoint() async throws {
    let backend = MockDeviceBackend()
    // Skipping a frame must not land two same-signed nudges in a row: an
    // identical resend never fires the bridge's completion and stalls the
    // gesture for the full send timeout. The first dwell wake skips a frame.
    let pacer = FakeGesturePacer(overshoots: [.zero, .milliseconds(33)])
    _ = try await SimInputSynthesis.swipe(
        backend: backend,
        paneId: UUID(),
        generation: 0,
        fromX: 0,
        fromY: 0,
        toX: 1,
        toY: 0,
        durationMs: 16,
        holdMs: 200,
        pacer: pacer
    )
    let dwellPoints = backend.tapDownPoints.dropFirst(2)
    #expect(dwellPoints.count > 1)
    #expect(!zip(dwellPoints, dwellPoints.dropFirst()).contains { $0 == $1 })
}

@Test
func aLateCrownRotationStillDeliversItsWholeDelta() async throws {
    let backend = MockDeviceBackend()
    let pacer = FakeGesturePacer(overshoots: [.milliseconds(48)])
    try await SimInputSynthesis.crown(
        backend: backend,
        paneId: UUID(),
        generation: 0,
        delta: 1.0,
        durationMs: 160,
        pacer: pacer
    )
    // Fewer sends than the ten the schedule planned...
    #expect(backend.crownDeltas.count < 10)
    // ...but a crown delta is relative, so the skipped samples fold into the
    // next send and the total rotation is exactly what was asked for.
    #expect(abs(backend.crownDeltas.reduce(0, +) - 1.0) < 0.000001)
}

@Test
func anOnScheduleCrownRotationStepsEvenly() async throws {
    let backend = MockDeviceBackend()
    try await SimInputSynthesis.crown(
        backend: backend,
        paneId: UUID(),
        generation: 0,
        delta: 1.0,
        durationMs: 160,
        pacer: FakeGesturePacer()
    )
    #expect(backend.crownDeltas.count == 10)
    #expect(backend.crownDeltas.allSatisfy { abs($0 - 0.1) < 0.000001 })
}

@Test
func aCrownRotationSpreadsItsDeltasAcrossTheWholeDuration() async throws {
    let backend = MockDeviceBackend()
    let pacer = FakeGesturePacer()
    try await SimInputSynthesis.crown(
        backend: backend,
        paneId: UUID(),
        generation: 0,
        delta: 1.0,
        durationMs: 160,
        pacer: pacer
    )
    // Each send follows its sleep, so the deadlines are the send schedule. The
    // last delta must land at 160ms, not at 144ms with the call idling out the
    // remaining interval: what matters is when the guest saw the rotation
    // finish, not when the RPC returned.
    #expect(pacer.requestedOffsets == (1...10).map { .milliseconds(160 * $0 / 10) })
    #expect(backend.crownDeltas.count == 10)
    // Nothing sleeps after the final send, so the call returns as it lands.
    #expect(pacer.elapsed == .milliseconds(160))
}
