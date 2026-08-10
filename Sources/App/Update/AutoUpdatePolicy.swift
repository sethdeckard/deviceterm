// SPDX-License-Identifier: GPL-3.0-or-later
//
// AutoUpdatePolicy: the typed form of the `auto-update` config key that
// drives Sparkle. The config value, not a Sparkle first-run prompt or a
// Preferences checkbox, is the on/off control.

import DaemonProtocol
import Foundation

enum AutoUpdatePolicy: String, CaseIterable, Equatable {
    /// No automatic checks; only the "Check for Updates…" menu item.
    case off
    /// Check automatically and notify when an update is available (default).
    case check
    /// Check, download, and install on relaunch automatically.
    case download

    static let configKey = "auto-update"

    /// The built-in default, sourced from the shared config-defaults table
    /// so it can't drift from `dump-config`.
    static let defaultPolicy = AutoUpdatePolicy(
        rawValue: DeviceTermConfigDefaults.values[configKey] ?? "check"
    ) ?? .check

    /// Whether Sparkle should check on its own schedule.
    var automaticallyChecksForUpdates: Bool { self != .off }
    /// Whether Sparkle should silently download + install found updates.
    var automaticallyDownloadsUpdates: Bool { self == .download }

    /// Resolve from a raw config string; nil or an unrecognized value
    /// falls back to the default.
    static func resolve(_ raw: String?) -> AutoUpdatePolicy {
        raw.flatMap(AutoUpdatePolicy.init(rawValue:)) ?? defaultPolicy
    }
}
