// SPDX-License-Identifier: GPL-3.0-or-later
//
// WireVersionRecoveryCoordinatorTests: the ladder's decision table.
//
// Two properties carry most of the value here, and both are the kind that pass
// by accident under a weaker test.
//
// The ladder must WAIT OUT the helper it asked to stop. `daemon.shutdown` acks a
// grace period before the daemon exits, so on the successful path the old helper
// may answer at least one more ping with the old version. A ladder that read that
// as failure would abandon exactly the case it exists for, and would do so on the
// happy path.
//
// And it must NOT signal a replacement that merely disagrees. The launchd job is
// `KeepAlive`/`SuccessfulExit false`, so a killed daemon is respawned; killing a
// replacement would make launchd start another exactly like it. That state is a
// registration pointing at the wrong bundle, not a process refusing to die.
//
// Every dependency is a closure, so none of this touches launchd, a real clock,
// or a connection.

@testable import App
import Foundation
import Testing

@MainActor
struct WireVersionRecoveryCoordinatorTests {
    /// Records which rungs ran, and replays a scripted sequence of handshake
    /// answers (the last one repeating once the script runs out).
    ///
    /// `@MainActor` so it is `Sendable` enough to be captured by the injected
    /// `sleep`, which the coordinator declares `@Sendable` because a real one
    /// crosses isolation.
    @MainActor
    private final class Harness {
        var shutdownCalls = 0
        var terminateCalls = 0
        var repairCalls = 0
        var finishCalls = 0
        var abandonCalls = 0
        var handshakes: [RecoveryHandshakeOutcome] = []
        var shutdown: VersionMismatchOutcome.Shutdown = .confirmed
        var terminate: HelperTerminationOutcome = .terminated(pid: 42)
        var repairError: (any Error)?
        var repairEnabled = true
        var pinned = true
        /// Advances only when the coordinator sleeps, so `verifySeconds` is
        /// reached deterministically instead of by wall time.
        var clock = Date(timeIntervalSince1970: 0)
        /// One verify window is `verifySeconds / interval` handshakes. Kept at
        /// four so a test that wants to exhaust exactly one window can say so
        /// without depending on the production defaults.
        var verifySeconds: TimeInterval = 1
        var verifyIntervalNanos: UInt64 = 250_000_000

        /// Handshakes consumed before one verify window gives up.
        var handshakesPerVerifyWindow: Int {
            Int(verifySeconds / (Double(verifyIntervalNanos) / 1_000_000_000))
        }

        private var handshakeIndex = 0

        func nextHandshake() -> RecoveryHandshakeOutcome {
            guard !handshakes.isEmpty else { return .unreachable("no script") }
            let index = min(handshakeIndex, handshakes.count - 1)
            handshakeIndex += 1
            return handshakes[index]
        }
    }

    private let mismatch = DaemonClientError.versionMismatch(client: "0.2.0", daemon: "9.9.9")

    private func makeCoordinator(_ harness: Harness) -> WireVersionRecoveryCoordinator {
        var deps = WireVersionRecoveryCoordinator.Dependencies(
            pinnedToIncompatibleHelper: { harness.pinned },
            requestShutdown: {
                harness.shutdownCalls += 1
                return harness.shutdown
            },
            terminateHelper: {
                harness.terminateCalls += 1
                return harness.terminate
            },
            repairRegistration: nil,
            handshake: { harness.nextHandshake() },
            finishRecovery: { harness.finishCalls += 1 },
            abandonRecovery: { harness.abandonCalls += 1 },
            sleep: { nanos in
                await MainActor.run {
                    harness.clock = harness.clock
                        .addingTimeInterval(Double(nanos) / 1_000_000_000)
                }
            }
        )
        if harness.repairEnabled {
            deps.repairRegistration = {
                harness.repairCalls += 1
                if let error = harness.repairError { throw error }
            }
        }
        deps.now = { harness.clock }
        deps.verifySeconds = harness.verifySeconds
        deps.verifyIntervalNanos = harness.verifyIntervalNanos
        deps.repairWaitSeconds = harness.verifySeconds
        return WireVersionRecoveryCoordinator(deps)
    }

    private func cause(_ resolution: WireVersionRecoveryCoordinator.Resolution) -> UpdateRestartCause? {
        guard case let .surrender(situation) = resolution else { return nil }
        return situation.cause
    }

    // MARK: - The happy paths

    @Test
    func anAcknowledgedShutdownFollowedByACompatibleHelperConnects() async {
        let harness = Harness()
        harness.handshakes = [.compatible]
        let resolution = await makeCoordinator(harness).recover(after: mismatch)

        #expect(resolution == .connected)
        #expect(harness.shutdownCalls == 1)
        #expect(harness.terminateCalls == 0)
        #expect(harness.repairCalls == 0)
        #expect(harness.finishCalls == 1)
        #expect(harness.abandonCalls == 0)
    }

    @Test
    func itWaitsOutTheHelperItAskedToStop() async {
        // The grace-period regression guard. The old helper answers twice more
        // with the old version before the replacement comes up; reading either
        // of those as a verdict would surrender on the happy path.
        let harness = Harness()
        harness.handshakes = [
            .sameHelperStillAnswering(pid: 42),
            .sameHelperStillAnswering(pid: 42),
            .compatible
        ]
        let resolution = await makeCoordinator(harness).recover(after: mismatch)

        #expect(resolution == .connected)
        #expect(harness.terminateCalls == 0)  // never needed the signal
        #expect(harness.repairCalls == 0)
    }

    @Test
    func itKillsOnlyTheHelperThatKeptAnswering() async {
        // The one condition SIGKILL actually treats: the process we asked to
        // stop is still there after the whole verify window.
        let harness = Harness()
        // Exactly one verify window of "still there", so the signal is the
        // thing that changes the answer rather than more waiting.
        harness.handshakes = Array(
            repeating: .sameHelperStillAnswering(pid: 42),
            count: harness.handshakesPerVerifyWindow
        ) + [.compatible]
        let resolution = await makeCoordinator(harness).recover(after: mismatch)

        #expect(resolution == .connected)
        #expect(harness.terminateCalls == 1)
        #expect(harness.repairCalls == 0)
    }

    // MARK: - The rung that must not run

    @Test
    func itDoesNotKillAReplacementThatIsMerelyIncompatible() async {
        // Killing this one would make launchd start another exactly like it.
        // The problem is the registration, so the ladder skips to the repair.
        let harness = Harness()
        harness.handshakes = [.incompatible(daemonVersion: "9.9.9", pid: 77)]
        let resolution = await makeCoordinator(harness).recover(after: mismatch)

        #expect(harness.terminateCalls == 0)
        #expect(harness.repairCalls == 1)
        #expect(cause(resolution) == .replacementStillIncompatible(daemonVersion: "9.9.9"))
    }

    @Test
    func itSkipsTheStopRungsWhenTheHelperWasAlreadyReplaced() async {
        // Nothing to ask or signal: the instance that answered the mismatched
        // ping is gone, so the only useful question is whether what is there now
        // matches.
        let harness = Harness()
        harness.pinned = false
        harness.handshakes = [.compatible]
        let resolution = await makeCoordinator(harness).recover(after: mismatch)

        #expect(resolution == .connected)
        #expect(harness.shutdownCalls == 0)
        #expect(harness.terminateCalls == 0)
    }

    // MARK: - Surrenders

    @Test
    func itSurrendersWhenTheHelperWouldNotStop() async {
        let harness = Harness()
        harness.handshakes = [.sameHelperStillAnswering(pid: 42)]
        harness.terminate = .failed("Operation not permitted")
        let resolution = await makeCoordinator(harness).recover(after: mismatch)

        guard case let .surrender(situation) = resolution else {
            Issue.record("expected a surrender, got \(resolution)")
            return
        }
        guard case .helperCouldNotBeStopped = situation.cause else {
            Issue.record("expected helperCouldNotBeStopped, got \(situation.cause)")
            return
        }
        #expect(situation.reregistered)
        #expect(harness.abandonCalls == 1)
        #expect(harness.finishCalls == 0)
    }

    @Test
    func itSurrendersWhenTheReplacementNeverStarts() async {
        let harness = Harness()
        harness.handshakes = [.unreachable("connection unavailable")]
        let resolution = await makeCoordinator(harness).recover(after: mismatch)

        guard case .replacementDidNotStart = cause(resolution) else {
            Issue.record("expected replacementDidNotStart, got \(String(describing: cause(resolution)))")
            return
        }
        #expect(harness.repairCalls == 1)
    }

    @Test
    func aPartialRepairSurrendersAsRegistrationNotRestored() async {
        // Unregistered but not re-registered: the helper IS stopped and nothing
        // will start it, which is a different problem from one that would not
        // stop, and must not borrow that copy.
        let harness = Harness()
        harness.handshakes = [.unreachable("connection unavailable")]
        harness.repairError = RegistrationRepairFailure(
            unregistered: true,
            underlying: DaemonClientError.transport("launchd refused")
        )
        let resolution = await makeCoordinator(harness).recover(after: mismatch)

        guard case .registrationNotRestored = cause(resolution) else {
            Issue.record("expected registrationNotRestored, got \(String(describing: cause(resolution)))")
            return
        }
    }

    @Test
    func aRepairThatFailedBeforeItsTeardownStillReachesAVerdict() async {
        // The teardown did not complete, so the registration's state is unknown
        // rather than known-unchanged. Either way the ladder falls through to
        // whatever the verify says rather than claiming a rebuild happened.
        let harness = Harness()
        harness.handshakes = [.sameHelperStillAnswering(pid: 42)]
        harness.terminate = .failed("Operation not permitted")
        harness.repairError = RegistrationRepairFailure(
            unregistered: false,
            underlying: DaemonClientError.transport("launchd refused")
        )
        let resolution = await makeCoordinator(harness).recover(after: mismatch)

        guard case .helperCouldNotBeStopped = cause(resolution) else {
            Issue.record("expected helperCouldNotBeStopped, got \(String(describing: cause(resolution)))")
            return
        }
    }

    @Test
    func aMissingRepairDependencySurrendersRatherThanLooping() async {
        // A transport with no repair capability disables the rung. Production
        // smoke mode never builds this coordinator at all, so this models a
        // configuration rather than that path.
        let harness = Harness()
        harness.repairEnabled = false
        harness.handshakes = [.unreachable("no transport")]
        let resolution = await makeCoordinator(harness).recover(after: mismatch)

        guard case let .surrender(situation) = resolution else {
            Issue.record("expected a surrender, got \(resolution)")
            return
        }
        #expect(!situation.reregistered)
        #expect(harness.repairCalls == 0)
    }

    // MARK: - Invariants across every path

    @Test
    func everyRungRunsAtMostOnce() async {
        let harness = Harness()
        harness.handshakes = Array(repeating: .sameHelperStillAnswering(pid: 42), count: 200)
        _ = await makeCoordinator(harness).recover(after: mismatch)

        #expect(harness.shutdownCalls <= 1)
        #expect(harness.terminateCalls <= 1)
        #expect(harness.repairCalls <= 1)
    }

    @Test
    func theTwoExitClosuresAreMutuallyExclusive() async {
        for script in [[RecoveryHandshakeOutcome.compatible], [.unreachable("gone")]] {
            let harness = Harness()
            harness.handshakes = script
            _ = await makeCoordinator(harness).recover(after: mismatch)
            #expect(harness.finishCalls + harness.abandonCalls == 1)
        }
    }

    @Test
    func theSurrenderDetailCarriesEveryRung() async {
        let harness = Harness()
        harness.handshakes = [.sameHelperStillAnswering(pid: 42)]
        harness.terminate = .failed("Operation not permitted")
        let resolution = await makeCoordinator(harness).recover(after: mismatch)

        guard case let .surrender(situation) = resolution else {
            Issue.record("expected a surrender, got \(resolution)")
            return
        }
        #expect(situation.detail.contains("9.9.9"))          // the mismatch itself
        #expect(situation.detail.contains("acknowledged"))   // rung 1
        #expect(situation.detail.contains("signalled"))      // rung 2
        #expect(situation.detail.contains("registration"))   // rung 3
    }

    @Test
    func anUnacknowledgedShutdownIsRecordedWithoutClaimingItStopped() async {
        let harness = Harness()
        harness.shutdown = .indeterminate("daemon.shutdown timed out awaiting acknowledgement")
        harness.handshakes = [.compatible]
        let resolution = await makeCoordinator(harness).recover(after: mismatch)

        #expect(resolution == .connected)
        #expect(harness.shutdownCalls == 1)
    }
}
