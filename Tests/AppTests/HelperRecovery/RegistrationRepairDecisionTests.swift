// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import ServiceManagement
import Testing

/// `RegistrationRepairDecision`: which launch failures are worth offering a
/// helper re-registration for.
///
/// The repair stops a running helper and discards everything it held, so the
/// gate matters in both directions. Every status other than `.enabled` wants a
/// different remedy, and any reply at all proves the registration resolves, so
/// only the enabled-yet-silent combination is a possible registration wedge.
struct RegistrationRepairDecisionTests {
    private static let unreachable = DaemonClientError.timedOut(method: "daemon.ping")

    /// The condition for which repair is offered: nothing answered while the
    /// registration claims to be enabled.
    @Test("offers the repair for silence from an enabled registration", arguments: [
        DaemonClientError.timedOut(method: "daemon.ping"),
        DaemonClientError.transport("daemon connection invalidated")
    ])
    func offersRepairWhenEnabledAndSilent(failure: DaemonClientError) {
        let decision = RegistrationRepairDecision.evaluate(
            failure: failure,
            status: .enabled,
            isSmokeMode: false
        )
        #expect(decision == .offerRepair)
    }

    /// These errors establish helper reachability, so they are not evidence of
    /// a registration-launch failure.
    @Test("never offers the repair when the helper answered", arguments: [
        DaemonClientError.daemon(code: -32_001, message: "unauthorized"),
        DaemonClientError.versionMismatch(client: "3", daemon: "4"),
        DaemonClientError.decode("unexpected payload"),
        DaemonClientError.shutdownNotAcknowledged,
        DaemonClientError.shutdownTimedOut
    ])
    func surfacesFailureWhenHelperAnswered(failure: DaemonClientError) {
        let decision = RegistrationRepairDecision.evaluate(
            failure: failure,
            status: .enabled,
            isSmokeMode: false
        )
        #expect(decision == .surfaceFailure)
    }

    /// Not registered, awaiting approval, or missing: each has its own remedy,
    /// and tearing down a registration serves none of them. `.requiresApproval`
    /// especially, where the user disabled the login item on purpose.
    @Test("never offers the repair for a non-enabled registration", arguments: [
        SMAppService.Status.notRegistered,
        SMAppService.Status.requiresApproval,
        SMAppService.Status.notFound
    ])
    func surfacesFailureWhenNotEnabled(status: SMAppService.Status) {
        let decision = RegistrationRepairDecision.evaluate(
            failure: Self.unreachable,
            status: status,
            isSmokeMode: false
        )
        #expect(decision == .surfaceFailure)
    }

    /// The hermetic gate runs on the UDS fallback, registers nothing, and must
    /// not mutate system state or block on a modal, so it never offers.
    @Test
    func neverOffersTheRepairUnderSmoke() {
        let decision = RegistrationRepairDecision.evaluate(
            failure: Self.unreachable,
            status: .enabled,
            isSmokeMode: true
        )
        #expect(decision == .surfaceFailure)
    }
}
