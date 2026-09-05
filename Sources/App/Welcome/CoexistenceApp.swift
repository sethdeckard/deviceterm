// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// One of Apple's device-facing apps that DeviceTerm has to coexist with.
///
/// Xcode 26 and earlier ship Simulator.app; Xcode 27 drops it and ships
/// Device Hub instead. A machine can have either app, both, or neither, so
/// the welcome catalog gates each explanation on the matching app being
/// there.
///
/// Everything that varies between the two lives here rather than as a bundle
/// id literal at the call site: the coexistence welcomes, the advisories, and
/// the illustrations all ask this type.
///
/// **Installed** and **running** answer different questions. A welcome teaches
/// a model the user will meet, so it turns on when the app is installed; an
/// advisory names a hazard that is live right now, so it turns on when the app
/// is running.
enum CoexistenceApp {
    /// Apple's Simulator.app, shipped through Xcode 26 at
    /// `Contents/Developer/Applications/Simulator.app`.
    case simulator

    /// Xcode 27's replacement, at `Contents/Applications/DeviceHub.app`. The
    /// bundle is `DeviceHub.app`; the name the app shows everywhere, and the
    /// one to write in prose, is **Device Hub**.
    case deviceHub

    /// The app's bundle identifier, which is also its preferences domain.
    ///
    /// Device Hub's does not follow its bundle name: the bundle is
    /// `DeviceHub.app` and the running process is `DeviceHub`, but the
    /// identifier is `com.apple.dt.Devices` and `CFBundleExecutable` is
    /// `DevicesTrampoline`.
    var bundleID: String {
        switch self {
        case .simulator:
            "com.apple.iphonesimulator"

        case .deviceHub:
            "com.apple.dt.Devices"
        }
    }

    /// What to call the app in a label too small for a sentence, matching
    /// what the Dock shows under its icon.
    ///
    /// Prose calls the first one Simulator.app, to keep it distinct from
    /// a simulator, but the Dock says "Simulator" and this follows the
    /// Dock.
    var displayName: String {
        switch self {
        case .simulator:
            "Simulator"

        case .deviceHub:
            "Device Hub"
        }
    }

    /// Whether the app is present on this machine, whether or not it is
    /// running.
    ///
    /// Both apps are nested inside an Xcode bundle rather than sitting in
    /// `/Applications`, and Launch Services resolves both by identifier
    /// anyway. It answers for whichever copy it would launch, which is not
    /// guaranteed to be the one `xcode-select -p` points at when several
    /// Xcodes are installed.
    func isInstalled() -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// Whether the app is running right now. Queried per decision rather than
    /// cached, so the answer is fresh at the moment a pane attaches.
    func isRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// The app's icon, in three tiers.
    ///
    /// The running instance first: that is literally the icon in the user's
    /// Dock, and it's the tier that applies whenever an advisory offers
    /// Learn More…, since the advisory fires only while the app is running.
    /// Launch Services second, which covers a Help-menu open and an
    /// automatic welcome alike, because a welcome is gated on the app being
    /// installed rather than running. Nil last, when it isn't installed at
    /// all, which the illustrations draw as an empty slot.
    func icon() -> NSImage? {
        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first?.icon
        if let running { return running }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
