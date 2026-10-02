// SPDX-License-Identifier: GPL-3.0-or-later

import ServiceManagement

/// What a launch does about the helper's launchd registration.
///
/// An ordinary launch never rebuilds an enabled registration while a helper is
/// running: unregistering stops it, and a fresh one restores nothing, so its
/// live sessions and panes are lost, another checkout's included. A registration
/// whose plist has changed is rebuilt only when no helper process is running,
/// where there is nothing to lose. Otherwise the rebuild waits for a later launch.
enum RegistrationRefreshDecision: Equatable {
    /// No enabled registration: register, which reads the current plist.
    case register
    /// Registered with the current plist; nothing to do.
    case upToDate
    /// Registered with an older plist and no helper process running: rebuild it.
    case repair
    /// Registered with an older plist, but a helper may be running: leave it
    /// for a later launch.
    case deferred

    /// `recorded` is nil when no fingerprint was ever recorded, which is how an
    /// install from before fingerprints reads. `presence` is consulted only
    /// when the registration is stale, so an up-to-date launch never probes.
    static func evaluate(
        status: SMAppService.Status,
        recorded: String?,
        current: String,
        presence: () -> HelperPresence
    ) -> Self {
        guard status == .enabled else { return .register }
        guard recorded != current else { return .upToDate }
        return presence() == .notRunning ? .repair : .deferred
    }
}
