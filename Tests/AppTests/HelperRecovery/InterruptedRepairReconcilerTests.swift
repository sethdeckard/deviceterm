// SPDX-License-Identifier: GPL-3.0-or-later
//
// InterruptedRepairReconcilerTests: what a launch does when it finds a repair an
// earlier process was terminated in the middle of.
//
// The states worth testing are all about timing and are unreachable against the
// real ServiceManagement: a replay that never completes, one that completes
// after the launch stopped waiting, and one that fails at either stage. The
// clock is injected and advances only when the reconciler sleeps, so a
// never-completing replay is exercised without the test taking that long.
//
// The property that matters most: a stalled replay must reach a visible outcome
// rather than parking the launch. `SMAppService.unregister()` honours no
// cancellation, so a launch that awaited a stuck one would never reach a window
// and would repeat that on every relaunch with nothing on screen.

@testable import App
import Foundation
import Testing

@MainActor
struct InterruptedRepairReconcilerTests {
    @MainActor
    private final class Harness {
        private let instance = UUID().uuidString
        var expectsHeldLock = true
        var underway = true
        var underwayError: (any Error)?
        /// The lock the launch holds. Nil models a wiring error: the
        /// reconciler must never take its own, because the launch holds one
        /// across registration and the handshake too.
        var heldLock: RegistrationRepairLock.Handle?
        /// When true the wait advances the clock WITHOUT yielding, so the
        /// spawned replay never gets a chance to start before the deadline.
        var nonYieldingSleep = false
        var repairCalls = 0
        /// Nil means the replay never completes.
        var repairResult: (any Error)?? = .some(nil)
        var clock = Date(timeIntervalSince1970: 0)
        var waitSeconds: TimeInterval = 1
        var pollIntervalNanos: UInt64 = 250_000_000
        /// Holds the replay until `releaseRepair()`, so a test can land its
        /// completion after the wait has already given up.
        var gateRepair = false
        private(set) var repairFinished = false
        private var gateOpen = false

        /// A per-harness lock file, so concurrent tests never contend with each
        /// other by accident.
        var lockPath: String {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("deviceterm-recon-\(instance)")
                .appendingPathComponent("registration-repair.lock")
                .path
        }

        func releaseRepair() { gateOpen = true }

        func waitForGate() async {
            while !gateOpen {
                await Task.yield()
            }
        }

        func noteRepairFinished() { repairFinished = true }

        func takeLock() throws {
            heldLock = try RegistrationRepairLock.tryAcquire(at: lockPath)
        }
    }

    private struct Boom: Error {}

    private func makeReconciler(_ harness: Harness) -> InterruptedRepairReconciler {
        // Every test but the wiring-error one runs with the launch's lock held,
        // matching production where the launch takes it before reconciling.
        if harness.heldLock == nil, harness.expectsHeldLock {
            try? harness.takeLock()
        }
        var deps = InterruptedRepairReconciler.Dependencies(
            heldLock: harness.heldLock,
            isRepairUnderway: {
                if let error = harness.underwayError { throw error }
                return harness.underway
            },
            repair: { held in
                harness.repairCalls += 1
                if harness.gateRepair {
                    // Hold the handle across the wait, as the real repair does,
                    // so the lock's lifetime is genuinely the replay's.
                    defer { withExtendedLifetime(held) {} }
                    await harness.waitForGate()
                    harness.noteRepairFinished()
                    return
                }
                guard let result = harness.repairResult else {
                    // Never completes: park past any deadline the test uses.
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    return
                }
                if let error = result { throw error }
            },
            sleep: { nanos in
                harness.clock = harness.clock
                    .addingTimeInterval(Double(nanos) / 1_000_000_000)
                // No await at all on the non-yielding path, so the wait reaches
                // its deadline without the spawned replay ever being scheduled.
                if !harness.nonYieldingSleep {
                    await Task.yield()
                }
            }
        )
        deps.now = { harness.clock }
        deps.waitSeconds = harness.waitSeconds
        deps.pollIntervalNanos = harness.pollIntervalNanos
        return InterruptedRepairReconciler(deps)
    }

    private func cause(_ outcome: InterruptedRepairReconciler.Outcome) -> UpdateRestartCause? {
        guard case let .surrender(situation) = outcome else { return nil }
        return situation.cause
    }

    @Test
    func noMarkerMeansNoWork() async {
        let harness = Harness()
        harness.underway = false

        #expect(await makeReconciler(harness).reconcile() == .nothingToDo)
        #expect(harness.repairCalls == 0)
    }

    @Test
    func aCompletedReplayReconciles() async {
        let harness = Harness()
        harness.repairResult = .some(.none)

        #expect(await makeReconciler(harness).reconcile() == .reconciled)
        #expect(harness.repairCalls == 1)
    }

    @Test
    func reconcilingWithoutTheLockFailsClosed() async {
        // The launch owns the lock and holds it across registration and the
        // version handshake, not just this call. Arriving without one is a
        // wiring error, and proceeding would defeat the barrier entirely.
        let harness = Harness()
        harness.expectsHeldLock = false

        let outcome = await makeReconciler(harness).reconcile()

        guard case .registrationStateUnknown = cause(outcome) else {
            Issue.record("expected an unknown-state surrender, got \(outcome)")
            return
        }
        #expect(harness.repairCalls == 0)
    }

    @Test
    func theReplayNeverReleasesTheLaunchesLock() async {
        // Releasing here would leave the registration and connect that follow
        // unprotected, which is the gap this scope exists to close.
        let harness = Harness()
        harness.repairResult = .some(.none)

        _ = await makeReconciler(harness).reconcile()

        #expect(harness.heldLock != nil)
    }

    @Test
    func anUnreadableMarkerReconcilesRatherThanSkipping() async {
        // Skipping is the reading that can leave a helper unregistered, so an
        // inspection that could not be completed does the work anyway.
        let harness = Harness()
        harness.underwayError = Boom()
        harness.repairResult = .some(.none)

        #expect(await makeReconciler(harness).reconcile() == .reconciled)
        #expect(harness.repairCalls == 1)
    }

    @Test
    func aReplayThatNeverCompletesReachesAVisibleOutcome() async {
        // The liveness guard. Without the bound this call would never return,
        // and the launch behind it would never reach a window.
        let harness = Harness()
        harness.repairResult = nil  // never completes

        let outcome = await makeReconciler(harness).reconcile()

        guard case .registrationRepairStalled = cause(outcome) else {
            Issue.record("expected a stalled surrender, got \(outcome)")
            return
        }
    }

    @Test
    func aStalledReplayDoesNotClaimTheRegistrationWasRebuilt() async {
        // `reregistered` drives copy telling the user macOS may show a
        // Background Activity notification. A replay still in flight has
        // triggered nothing to warn about.
        let harness = Harness()
        harness.repairResult = nil

        guard case let .surrender(situation) = await makeReconciler(harness).reconcile() else {
            Issue.record("expected a surrender")
            return
        }
        #expect(!situation.reregistered)
    }

    @Test
    func aFailureAfterTheTeardownSurrendersAsRegistrationNotRestored() async {
        let harness = Harness()
        harness.repairResult = .some(
            RegistrationRepairFailure(unregistered: true, underlying: Boom())
        )

        let outcome = await makeReconciler(harness).reconcile()

        guard case .registrationNotRestored = cause(outcome) else {
            Issue.record("expected registrationNotRestored, got \(outcome)")
            return
        }
        guard case let .surrender(situation) = outcome else { return }
        // Torn down and NOT stood back up: the rebuild is exactly what did not
        // happen, so this must not claim it did.
        #expect(!situation.reregistered)
    }

    @Test
    func aFailureBeforeTheTeardownStillBlocksTheLaunch() async {
        // `unregistered` describes THIS attempt, and the marker exists because
        // an EARLIER one was interrupted. A replay that stopped before its own
        // teardown proves nothing about whether the helper is still registered,
        // so proceeding could register or connect over a teardown still in
        // flight. The stage explains; it does not decide.
        let harness = Harness()
        harness.repairResult = .some(
            RegistrationRepairFailure(unregistered: false, underlying: Boom())
        )

        let outcome = await makeReconciler(harness).reconcile()

        // Unknown, not "the helper stopped": `.registrationNotRestored` tells the
        // user their helper definitely stopped, which nobody here knows.
        guard case .registrationStateUnknown = cause(outcome) else {
            Issue.record("expected the launch to stay gated as unknown, got \(outcome)")
            return
        }
        guard case let .surrender(situation) = outcome else { return }
        #expect(!situation.reregistered)
    }

    @Test
    func onlyAKnownTeardownClaimsTheHelperStopped() async {
        // The pair that keeps the two causes honest: the same failure type maps
        // to different causes purely on whether the teardown is known to have
        // happened.
        let after = Harness()
        after.repairResult = .some(
            RegistrationRepairFailure(unregistered: true, underlying: Boom())
        )
        let before = Harness()
        before.repairResult = .some(
            RegistrationRepairFailure(unregistered: false, underlying: Boom())
        )

        let knownStopped = cause(await makeReconciler(after).reconcile())
        let unknown = cause(await makeReconciler(before).reconcile())

        guard case .registrationNotRestored = knownStopped else {
            Issue.record("expected registrationNotRestored, got \(String(describing: knownStopped))")
            return
        }
        guard case .registrationStateUnknown = unknown else {
            Issue.record("expected registrationStateUnknown, got \(String(describing: unknown))")
            return
        }
    }

    @Test
    func theLockStaysHeldUntilAnAbandonedReplayFinishes() async {
        // The point of the whole scope. The launch gives up waiting and lets go
        // of its reference, but the replay is still tearing the registration
        // down, so the lock must NOT drop: another copy of DeviceTerm acquiring
        // here would begin its own teardown over ours.
        //
        // `nonYieldingSleep` makes the wait reach its deadline without the
        // replay ever being scheduled, which is also what releases the
        // reconciler before the task body runs. Reaching the repair through
        // `self?` would skip it entirely at that point.
        let harness = Harness()
        harness.nonYieldingSleep = true
        harness.gateRepair = true

        weak var released: InterruptedRepairReconciler?
        var outcome: InterruptedRepairReconciler.Outcome?
        do {
            let reconciler = makeReconciler(harness)
            released = reconciler
            outcome = await reconciler.reconcile()
        }

        #expect(harness.repairCalls == 0)  // the task never got to start
        #expect(released == nil)           // and nothing retains the reconciler
        guard case .registrationRepairStalled = cause(outcome ?? .nothingToDo) else {
            Issue.record("expected a stalled surrender, got \(String(describing: outcome))")
            return
        }

        // The launch lets go, exactly as its `defer` does.
        harness.heldLock = nil

        // Still contended: the replay owns the same handle and is not done.
        let contended = try? RegistrationRepairLock.tryAcquire(at: harness.lockPath)
        #expect(contended == nil)

        harness.releaseRepair()
        var pumps = 0
        while !harness.repairFinished, pumps < 1_000 {
            pumps += 1
            await Task.yield()
        }
        #expect(harness.repairFinished)
        #expect(harness.repairCalls == 1)

        // And released once the replay is done, so the next launch can proceed.
        var reacquired = try? RegistrationRepairLock.tryAcquire(at: harness.lockPath)
        #expect(reacquired != nil)
        reacquired = nil
    }

    @Test
    func theReplayIsStartedExactlyOnce() async {
        let harness = Harness()
        harness.repairResult = nil

        _ = await makeReconciler(harness).reconcile()

        #expect(harness.repairCalls == 1)
    }
}
