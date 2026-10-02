// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import ServiceManagement
import Testing

/// What a launch does about the helper's registration.
///
/// The property that matters: a stale registration is rebuilt only when the
/// process scan reports no helper running. Rebuilding under a running helper discards
/// its live sessions and panes.
struct RegistrationRefreshDecisionTests {
    @Test("the registration status, fingerprint, and helper decide the refresh", arguments: [
        (
            SMAppService.Status.notRegistered, nil as String?,
            HelperPresence.running, RegistrationRefreshDecision.register
        ),
        (.notFound, "old", .notRunning, .register),
        (.requiresApproval, "new", .notRunning, .register),
        (.enabled, "new", .running, .upToDate),
        (.enabled, "old", .notRunning, .repair),
        (.enabled, nil, .notRunning, .repair),
        (.enabled, "old", .running, .deferred),
        (.enabled, "old", .unknown, .deferred),
        (.enabled, nil, .unknown, .deferred)
    ])
    func decides(
        status: SMAppService.Status,
        recorded: String?,
        presence: HelperPresence,
        expected: RegistrationRefreshDecision
    ) {
        let decision = RegistrationRefreshDecision.evaluate(
            status: status,
            recorded: recorded,
            current: "new",
            presence: { presence }
        )
        #expect(decision == expected)
    }

    @Test
    func anUpToDateRegistrationNeverProbes() {
        var probes = 0
        _ = RegistrationRefreshDecision.evaluate(
            status: .enabled,
            recorded: "new",
            current: "new",
            presence: {
                probes += 1
                return .notRunning
            }
        )
        #expect(probes == 0)
    }
}
