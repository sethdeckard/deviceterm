// SPDX-License-Identifier: GPL-3.0-or-later
//
// RegistrationRepairDecision: whether a failed launch connection is worth
// offering a helper re-registration for.
//
// `SMAppService`'s `.enabled` reports the BTM disposition, not whether launchd
// can spawn the job. A launchd job that outlives the BTM record it resolves the
// helper's relative path against still reads as enabled while every spawn dies
// in `xpcproxy`, and `registerOnFirstLaunch()` takes its early return on that
// status, so relaunching repeats the failure exactly. Re-registering rebuilds
// the job.
//
// Re-registering is destructive: unregistering stops a *running* helper, and a
// fresh one restores nothing from disk. The same symptom has benign causes (a
// blip, a helper still coming up), and the startup handshake is a single
// bounded ping with no retry, so this decision does not try to tell them apart.
// It decides only whether the repair is worth *offering*; the user consents to
// the destruction, and the caller re-evaluates after they answer, since the
// status can change while the prompt is up.

import ServiceManagement

enum RegistrationRepairDecision: Equatable {
    /// Offer to re-register, then quit. Nothing answered, and the registration
    /// claims to be enabled: the condition for which repair is offered.
    case offerRepair
    /// Do not offer repair; surface the connection failure unchanged.
    case surfaceFailure

    static func evaluate(
        failure: DaemonClientError,
        status: SMAppService.Status,
        isSmokeMode: Bool
    ) -> Self {
        // The hermetic gate runs on the UDS fallback, registers nothing, and
        // must not touch system state or block on a modal.
        guard !isSmokeMode else { return .surfaceFailure }
        // A helper that answered, even to report an error or a version
        // mismatch, has a registration that resolves.
        guard failure.isHelperUnreachable else { return .surfaceFailure }
        // Every other status wants a different remedy: `register()` when there
        // is no registration, or System Settings when the user disabled it.
        // None is served by tearing one down.
        guard status == .enabled else { return .surfaceFailure }
        return .offerRepair
    }
}
