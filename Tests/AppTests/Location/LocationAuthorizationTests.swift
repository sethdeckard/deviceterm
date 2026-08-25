// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

// LocationAuthorizationTests: the permission state machine behind Use My
// Location, with no CoreLocation and no TCC.
//
// Two timing rules define this state machine.
//
// The first is about *when* anything may happen: wait for the manager's
// first status report before acting. A freshly built
// `CLLocationManager` has not synced with the location daemon, and until
// it has, reading its status or asking it for permission is unreliable,
// and the request can be dropped with no prompt and no callback.
//
// The second is about *what a report means*: after requesting
// authorization, `notDetermined` is pending, not an answer. Reports
// reach the main actor like every other callback, so one can arrive
// after the request that followed it, and `notDetermined` is the state a
// request asks from.

// MARK: - Phases

/// A new manager must report its status before the request begins. Its
/// `authorizationStatus` can read `notDetermined` for an app that is
/// already decided, and a `requestWhenInUseAuthorization()` issued before
/// the sync is dropped with no prompt and no callback, leaving nothing
/// but a timeout to resolve the request. So the first report *starts*
/// the request rather than being filtered out as noise.
@Test("the manager's first report is what asks for permission")
func theFirstReportStartsTheRequest() {
    #expect(
        LocationAuthorization.notDetermined.step(reportedIn: .awaitingReady)
            == .requestAuthorization
    )
}

/// Already-decided permission needs no prompt, so the same first report
/// goes straight for a position.
@Test("an already-authorized first report asks for a position")
func anAuthorizedFirstReportAsksForAFix() {
    #expect(LocationAuthorization.allowed.step(reportedIn: .awaitingReady) == .requestLocation)
}

/// Once the prompt is open, a `notDetermined` report is not its
/// answer.
@Test("a report while the prompt is up is not its answer")
func aReportWhileAwaitingAuthorizationIsNotAnAnswer() {
    #expect(
        LocationAuthorization.notDetermined.step(reportedIn: .awaitingAuthorization)
            == .keepWaiting
    )
}

/// Reports arrive for reasons of their own, including the user changing
/// the setting in System Settings while nothing is pending. Acting on
/// one would ask for a position nobody requested.
@Test("a report with nothing pending does nothing", arguments: [
    LocationRequestPhase.idle,
    .awaitingFix
])
func aReportWithNothingPendingDoesNothing(phase: LocationRequestPhase) {
    for status in [LocationAuthorization.notDetermined, .allowed, .denied, .restricted] {
        #expect(status.step(reportedIn: phase) == .keepWaiting)
    }
}

/// A refusal is a refusal whenever it turns up, so it resolves the
/// request in either waiting phase rather than only the one that asked.
@Test("a refusal resolves the request from either waiting phase", arguments: [
    LocationRequestPhase.awaitingReady,
    .awaitingAuthorization
])
func aRefusalResolvesFromEitherWaitingPhase(phase: LocationRequestPhase) {
    #expect(LocationAuthorization.denied.step(reportedIn: phase) == .finish(.denied))
    #expect(LocationAuthorization.restricted.step(reportedIn: phase) == .finish(.restricted))
}

// MARK: - The step table

/// `notDetermined` is the state a request starts from, so it cannot
/// answer that request.
@Test("a notDetermined callback is not an answer")
func waitingOnNotDeterminedKeepsWaiting() {
    #expect(LocationAuthorization.notDetermined.waitingStep == .keepWaiting)
}

/// The same status means the opposite thing before a request has been
/// made, which is the entire reason the two steps are separate.
@Test("a notDetermined start asks for permission")
func startingOnNotDeterminedAsks() {
    #expect(LocationAuthorization.notDetermined.startingStep == .requestAuthorization)
}

/// Asking twice would stack a second prompt behind the first.
@Test("waiting never asks for permission again", arguments: [
    LocationAuthorization.notDetermined,
    .allowed,
    .denied,
    .restricted,
    .unrecognized
])
func waitingNeverRequestsAuthorizationAgain(status: LocationAuthorization) {
    #expect(status.waitingStep != .requestAuthorization)
}

@Test("permission in hand asks for a position")
func allowedRequestsALocation() {
    #expect(LocationAuthorization.allowed.startingStep == .requestLocation)
    #expect(LocationAuthorization.allowed.waitingStep == .requestLocation)
}

/// A settled refusal reads the same whenever it arrives. Only
/// `notDetermined` differs between the two, so anything else answering
/// differently would be a bug rather than a design.
@Test("a settled state resolves the same way from either step", arguments: [
    (LocationAuthorization.denied, LocationAuthorizationStep.finish(.denied)),
    (.restricted, .finish(.restricted))
])
func settledStatesAgree(status: LocationAuthorization, expected: LocationAuthorizationStep) {
    #expect(status.startingStep == expected)
    #expect(status.waitingStep == expected)
}

/// A status this build doesn't know must still resolve the request.
/// Leaving it pending would be indistinguishable from a hang.
@Test("an unrecognized state still resolves")
func unrecognizedFinishes() {
    let steps = [
        LocationAuthorization.unrecognized.startingStep,
        LocationAuthorization.unrecognized.waitingStep
    ]
    for step in steps {
        guard case let .finish(fix) = step else {
            Issue.record("an unknown permission state left the request pending")
            continue
        }
        guard case let .unavailable(reason) = fix else {
            Issue.record("an unknown permission state was reported as a known outcome")
            continue
        }
        #expect(!reason.isEmpty)
    }
}
