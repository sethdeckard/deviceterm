// SPDX-License-Identifier: GPL-3.0-or-later
//
// RegistrationRepairTransactionTests: the ordering that makes an interrupted
// repair recoverable.
//
// These assert SEQUENCE, not end state. A repair that ends with the marker
// absent and the job registered looks correct from the outside whether or not
// the marker was ever written before the teardown, and it is that ordering, not
// the outcome, that decides whether a process terminated mid-repair leaves the
// user with a helper.
//
// Driven entirely through injected legs, because the real `SMAppService` calls
// mutate the login session's launchd domain and would take the user's running
// helper with them.

@testable import App
import Foundation
import Testing

@MainActor
struct RegistrationRepairTransactionTests {
    /// Records the order the legs ran in, and can fail any of them.
    @MainActor
    private final class Legs {
        private(set) var order: [String] = []
        var markError: (any Error)?
        var unregisterError: (any Error)?
        var registerError: (any Error)?
        var clearError: (any Error)?
        var benign = false

        func transaction() -> RegistrationRepairTransaction {
            RegistrationRepairTransaction(
                markUnderway: { [self] in
                    order.append("mark")
                    if let markError { throw markError }
                },
                unregister: { [self] in
                    order.append("unregister")
                    if let unregisterError { throw unregisterError }
                },
                register: { [self] in
                    order.append("register")
                    if let registerError { throw registerError }
                },
                clearUnderway: { [self] in
                    order.append("clear")
                    if let clearError { throw clearError }
                },
                isBenignUnregisterFailure: { [self] _ in benign }
            )
        }
    }

    private struct Boom: Error {}

    private func stage(_ error: any Error) -> Bool? {
        (error as? RegistrationRepairFailure)?.unregistered
    }

    @Test
    func theHappyPathMarksBeforeTearingDownAndClearsAfterStandingBackUp() async throws {
        let legs = Legs()
        try await legs.transaction().run()
        #expect(legs.order == ["mark", "unregister", "register", "clear"])
    }

    @Test
    func aFailedMarkAbortsBeforeAnythingIsTornDown() async {
        // The whole point of the ordering: a teardown that outruns its marker
        // can be interrupted into a state nothing knows to finish.
        let legs = Legs()
        legs.markError = Boom()
        do {
            try await legs.transaction().run()
            Issue.record("expected the repair to abort")
        } catch {
            #expect(stage(error) == false)
        }
        #expect(legs.order == ["mark"])  // never reached the teardown
    }

    @Test
    func aFailedUnregisterReportsTheTeardownDidNotComplete() async {
        let legs = Legs()
        legs.unregisterError = Boom()
        do {
            try await legs.transaction().run()
            Issue.record("expected the repair to fail")
        } catch {
            // Teardown did not complete, so the registration state is unknown.
            #expect(stage(error) == false)
        }
        #expect(legs.order == ["mark", "unregister"])  // never registered, never cleared
    }

    @Test
    func aBenignUnregisterFailureCountsTheTeardownAsSatisfied() async throws {
        // A job booted out from under a BTM record still reading enabled is one
        // of the shapes a repair is called for, so job-not-found means the leg
        // is already done rather than that it failed. This is what lets a replay
        // converge from a phase where the teardown already happened.
        let legs = Legs()
        legs.unregisterError = Boom()
        legs.benign = true
        try await legs.transaction().run()
        #expect(legs.order == ["mark", "unregister", "register", "clear"])
    }

    @Test
    func aFailedRegisterReportsThatTheHelperIsStopped() async {
        // The state that must never be described as "couldn't stop the helper":
        // it stopped, and now nothing will start it.
        let legs = Legs()
        legs.registerError = Boom()
        do {
            try await legs.transaction().run()
            Issue.record("expected the repair to fail")
        } catch {
            #expect(stage(error) == true)
        }
        #expect(legs.order == ["mark", "unregister", "register"])  // never cleared
    }

    @Test
    func aFailedClearDoesNotFailTheRepair() async throws {
        // The registration is whole at that point. A marker left behind costs
        // one redundant reconciliation; a repair reported as failed would cost
        // the user a screen they do not need.
        let legs = Legs()
        legs.clearError = Boom()
        try await legs.transaction().run()
        #expect(legs.order == ["mark", "unregister", "register", "clear"])
    }

    @Test
    func aNonStagedErrorFromAlegIsStillReportedWithAStage() async {
        // Callers branch on `unregistered`, so every failure has to carry one.
        let legs = Legs()
        legs.markError = Boom()
        do {
            try await legs.transaction().run()
            Issue.record("expected the repair to fail")
        } catch {
            #expect(error is RegistrationRepairFailure)
        }
    }
}
