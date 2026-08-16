// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimulatorDetachPolicy: whether Apple's Simulator.app will leave a
// booted sim running when it goes away, read from that app's own
// preferences.
//
// Simulator.app does not use CoreSimulator's owner-death mechanism; it
// calls `shutdown` explicitly when a device window closes or the app
// quits. Two `com.apple.iphonesimulator` defaults turn that into a
// detach instead. Their menu items live under Simulator.app's
// AppleInternal-gated "Internal" menu, so most users have no UI for
// them, but the keys themselves are ordinary persisted preferences.
//
// Verified behavior (scratch sim, iPhone 17 Pro / iOS 26.5):
//
//   - Closing the *last* device window quits Simulator.app outright, so
//     that path is governed by `DetachOnAppQuit`. Setting only
//     `DetachOnWindowClose` did not save the sim.
//   - Externally written values are honored; the Internal menu is not
//     required to set them.
//   - The value is read at quit time, not cached at launch, so a change
//     takes effect without restarting Simulator.app, in both directions.
//
// `DetachOnWindowClose` is carried here because it governs closing one
// device window while others stay open, which the trials did not
// isolate. Treat its effect as documented-but-unverified.
//
// Reading another app's domain works because DeviceTerm is not
// sandboxed (private CoreSimulator APIs preclude it; see
// docs/BUILDING.md). `CFPreferencesCopyAppValue` rather than
// `UserDefaults(suiteName:)` because it reads a foreign domain
// directly. Whether it picks up a change made after this process
// started has not been tested; the manual checklist relaunches
// DeviceTerm between cases rather than relying on it.

import Foundation

struct SimulatorDetachPolicy: Sendable, Equatable {
    /// Apple's Simulator.app bundle identifier, which is also its
    /// preferences domain.
    static let simulatorBundleID = "com.apple.iphonesimulator"

    /// Closing one device window detaches instead of shutting the sim
    /// down. Only reached when other device windows remain open; the
    /// last one routes through quit.
    let detachOnWindowClose: Bool

    /// Quitting Simulator.app leaves booted sims running. This is the
    /// one that matters in practice.
    let detachOnAppQuit: Bool

    /// Read both keys from Simulator.app's preferences. An absent key
    /// reads as `false`, matching the observed default: sims shut down.
    static func current() -> SimulatorDetachPolicy {
        SimulatorDetachPolicy(
            detachOnWindowClose: flag("DetachOnWindowClose") ?? false,
            // Simulator.app carries a misspelled legacy key and a
            // migration class that rewrites it to the modern spelling.
            // Consult the legacy one only when the modern key is
            // absent: OR-ing them would let a stale `YES` override a
            // migrated `NO`.
            detachOnAppQuit: flag("DetachOnAppQuit") ?? flag("DetatchOnAppQuit") ?? false
        )
    }

    /// One preference as a boolean, or nil when the key is absent or
    /// holds something that isn't a boolean.
    private static func flag(_ key: String) -> Bool? {
        let value = CFPreferencesCopyAppValue(
            key as CFString,
            simulatorBundleID as CFString
        )
        return (value as? NSNumber)?.boolValue
    }
}
