// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Which processes could be the target behind a bundle id.
///
/// A bundle id names an identity, not a process. deviceterm's app and
/// daemon are singletons in normal use, but the GUI smoke launches its own
/// app and spawns its own daemon from the bundle's LoginItems, so a second
/// live instance under either id is reachable while a harness run is in
/// flight.
///
/// Ownership derived from on-screen windows alone would miss an instance
/// showing nothing, and that is often the instance the caller meant: the
/// daemon hides its status item at zero owned booted sims, and an app can
/// sit windowless. Were the hidden one the target, a visible second
/// instance would be captured in its place and read as a real answer. So
/// the process list is consulted too, and the two sources are unioned.
enum TargetOwners {
    /// Live pids registered under `bundleID`, sorted so messages are stable.
    static func live(bundleID: String) -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map(\.processIdentifier)
            .sorted()
    }

    /// Every process that could be the target: those registered under the
    /// bundle id, plus any the window server attributes windows to.
    ///
    /// Include window owners missing from the process list because their
    /// windows remain capture candidates.
    static func combined(processes: [pid_t], windowOwners: Set<pid_t>) -> Set<pid_t> {
        Set(processes).union(windowOwners)
    }
}
