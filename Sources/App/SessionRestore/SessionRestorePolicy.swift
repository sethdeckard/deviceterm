// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// The typed form of the `restore-session` config key: whether the app records
/// its layout and reopens it at the next launch.
enum SessionRestorePolicy: String, CaseIterable, Equatable {
    /// Record the layout and restore it at launch (default).
    case on // swiftlint:disable:this identifier_name
    /// Record nothing and open one new window at launch.
    case off

    static let configKey = "restore-session"

    /// The built-in default, sourced from the shared config-defaults table
    /// so it can't drift from `dump-config`.
    static let defaultPolicy = SessionRestorePolicy(
        rawValue: DeviceTermConfigDefaults.values[configKey] ?? "on"
    ) ?? .on

    /// Resolve from a raw config string; nil or an unrecognized value falls
    /// back to the default.
    static func resolve(_ raw: String?) -> SessionRestorePolicy {
        raw.flatMap(SessionRestorePolicy.init(rawValue:)) ?? defaultPolicy
    }
}
