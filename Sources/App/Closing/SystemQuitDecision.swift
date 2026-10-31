// SPDX-License-Identifier: GPL-3.0-or-later

import CoreServices

/// Whether a quit is part of a restart, shutdown, or log out, so the quit
/// path can skip prompts that would block it.
enum SystemQuitDecision {
    /// The `kAEQuitReason` values that mean the system is going down or
    /// the user is logging out. `kAEQuitAll` is left out: it isn't one.
    static let systemReasons: Set<OSType> = [
        OSType(kAEShutDown),
        OSType(kAERestart),
        OSType(kAEReallyLogOut),
        OSType(kAELogOut)
    ]

    /// `reason` is the quit Apple Event's `kAEQuitReason`, nil when the
    /// event carries none. `powerOffNotified` is whether
    /// `NSWorkspace.willPowerOffNotification` has been posted.
    static func isSystemQuit(reason: OSType?, powerOffNotified: Bool) -> Bool {
        if powerOffNotified { return true }
        guard let reason else { return false }
        return systemReasons.contains(reason)
    }
}
