// SPDX-License-Identifier: GPL-3.0-or-later
//
// DaemonRegistration: thin wrapper around
// `SMAppService.agent(plistName:)`.
//
// macOS 13+ exposes a Swift API for what was historically
// SMJobBless: register a launchd plist embedded under
// `Contents/Library/LaunchAgents/` and let launchd own the
// helper's lifecycle. The wrapper:
//
//   - Wraps the plist-name constant and the `register()` call so
//     callers see one entry point.
//   - Exposes the current `Status` so the GUI can branch into
//     `DaemonStatusSheet` for the disabled-helper case.
//   - Is idempotent, so calling `register()` on every launch is
//     fine; macOS no-ops the second call when the helper is
//     already enabled.

import Foundation
import ServiceManagement

@MainActor
enum DaemonRegistration {
    /// The LaunchAgent plist embedded at
    /// `Contents/Library/LaunchAgents/<plistName>` in the .app
    /// bundle. Matches the bundle id convention `<host>.daemon`
    /// for the agent label.
    static let plistName = "com.deviceterm.daemon.plist"

    /// The `SMAppService` error domain, spelled literally because the SDK
    /// constant `SMAppServiceErrorDomain` requires macOS 15 while the
    /// deployment target is macOS 14.
    private static let appServiceErrorDomain = "SMAppServiceErrorDomain"

    /// Read the current registration status without mutating
    /// system state. Wrapper around `SMAppService.agent.status`.
    static var status: SMAppService.Status {
        SMAppService.agent(plistName: plistName).status
    }

    /// Register the agent. Idempotent, so call it on every launch.
    /// Throws if launchd refuses (rare; typically signaling a
    /// signature problem).
    static func register() throws {
        try SMAppService.agent(plistName: plistName).register()
    }

    /// Unregister the agent. Used by tests + uninstall paths.
    static func unregister() throws {
        try SMAppService.agent(plistName: plistName).unregister()
    }

    /// Best-effort registration at first launch. Surfaces the
    /// macOS "Background Activity" notification once. If the
    /// register call throws, the caller can show
    /// `DaemonStatusSheet` to walk the user through enabling it
    /// in System Settings.
    ///
    /// The early return keeps an ordinary launch from churning launchd and
    /// BTM, at the cost of trusting `.enabled`. That status reports the BTM
    /// *disposition*, not whether launchd can actually spawn the job, so it
    /// cannot detect a wedged registration; `repair()` is what recovers one.
    static func registerOnFirstLaunch() throws {
        let service = SMAppService.agent(plistName: plistName)
        if service.status == .enabled { return }
        try service.register()
    }

    /// Force a clean re-registration of the agent.
    ///
    /// `register()` alone cannot fix a registration whose launchd job has gone
    /// stale, because the job is only rebuilt when the service is registered
    /// anew. The job stores the relative `BundleProgram` from the plist plus
    /// the BTM record identifying the bundle to resolve it against; when the
    /// job outlives that record, launchd can no longer resolve the helper's
    /// path and every spawn dies in `xpcproxy` with `EX_CONFIG`, while BTM
    /// still reports the agent enabled. Tearing the registration down and
    /// standing it back up re-links the two.
    ///
    /// The unregister tolerates exactly one failure, "no job by that label",
    /// which is a state the repair recovers from rather than a problem: a job
    /// booted out from under a BTM record still reading enabled is one of the
    /// shapes this is called for. It is awaited so launchd finishes the
    /// teardown before the re-registration, rather than racing it.
    ///
    /// Other unregister failures propagate so the caller cannot report a repair
    /// after teardown failed.
    ///
    /// Destructive, and not only costlier than `registerOnFirstLaunch()` (which
    /// it can also outdo by re-surfacing the "Background Activity"
    /// notification): the unregister STOPS a running helper, and a fresh one
    /// restores nothing from disk, so any live session, pane, and device state
    /// it held is gone. The symptom it treats has benign causes that cannot be
    /// told apart from the wire, so a caller acting on a *symptom* asks the user
    /// before calling this rather than inferring consent;
    /// `RegistrationRepairDecision` gates which failures are even worth asking
    /// about.
    ///
    /// The wire-version recovery ladder is the one caller that runs it
    /// unattended, and it is a different situation rather than an exception to
    /// that rule. It acts on a *definite* mismatch, not an ambiguous symptom,
    /// and only after its ladder has conditionally asked the helper to stop,
    /// signalled it, or found neither applicable, according to what each
    /// verification returned. It runs at startup, where this GUI holds no session, pane, or
    /// device state for the unregister to destroy. What it cannot avoid is the
    /// "Background Activity" notification, and that the helper is a per-user
    /// singleton: another checkout's GUI loses its helper too.
    ///
    /// It leaves no connection behind either. Callers either quit afterward or
    /// re-handshake from scratch, so nothing here has to reconcile a transport
    /// with the registration it just replaced.
    ///
    /// The marker is written first and a failure to write it aborts before
    /// anything is torn down; see `RegistrationRepairStore` for why that
    /// ordering is the whole guarantee.
    /// `holding` is the repair lock. It is a parameter rather than something
    /// this acquires, so a repair cannot be started without exclusion: the
    /// signature carries the requirement instead of a comment asking callers to
    /// remember. The helper is a per-user singleton, so two copies of DeviceTerm
    /// repairing at once would have one register while the other is between its
    /// unregister and its register.
    static func repair(
        store: RegistrationRepairStore,
        holding lock: RegistrationRepairLock.Handle
    ) async throws {
        // Hold the lock for the whole transaction. Without this, ARC is free to
        // release the handle after its last use, which is the top of the
        // function, and the exclusion would end before the teardown began.
        defer { withExtendedLifetime(lock) {} }
        try await transaction(store: store).run()
    }

    /// The repair sequence bound to the real ServiceManagement calls.
    ///
    /// Exposed so a caller can hold the transaction rather than the effect, and
    /// so the ordering can be exercised against injected legs; see
    /// `RegistrationRepairTransaction` for why that separation exists.
    static func transaction(store: RegistrationRepairStore) -> RegistrationRepairTransaction {
        RegistrationRepairTransaction(
            markUnderway: { try store.markRepairUnderway() },
            unregister: { try await service().unregister() },
            register: { try service().register() },
            clearUnderway: { try store.clearRepairUnderway() },
            isBenignUnregisterFailure: { isJobNotFound($0 as NSError) }
        )
    }

    private static func service() -> SMAppService {
        SMAppService.agent(plistName: plistName)
    }

    /// Whether an `unregister()` failure is the benign "no job by that label".
    ///
    /// Matched on the ServiceManagement domain as well as the code, so an
    /// unrelated error that happens to carry the same code isn't read as this
    /// one. A job-not-found reported under some other domain therefore
    /// propagates, which is the safe direction: it costs an accurate error the
    /// user can retry, where the reverse would claim a repair that did not
    /// happen.
    static func isJobNotFound(_ error: NSError) -> Bool {
        error.domain == appServiceErrorDomain && error.code == kSMErrorJobNotFound
    }
}
