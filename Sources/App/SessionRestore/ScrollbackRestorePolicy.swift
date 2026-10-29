// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// The typed form of the `restore-scrollback` config key: whether a restored
/// terminal shows the scrollback it had at quit.
enum ScrollbackRestorePolicy: String, CaseIterable, Equatable {
    /// Save no scrollback, and delete what was saved (default).
    case off
    /// Save each terminal's scrollback at quit and replay it on restore.
    case on // swiftlint:disable:this identifier_name

    static let configKey = "restore-scrollback"

    /// The built-in default, sourced from the shared config-defaults table
    /// so it can't drift from `dump-config`.
    static let defaultPolicy = ScrollbackRestorePolicy(
        rawValue: DeviceTermConfigDefaults.values[configKey] ?? "off"
    ) ?? .off

    /// Resolve from a raw config string; nil or an unrecognized value falls
    /// back to the default.
    static func resolve(_ raw: String?) -> ScrollbackRestorePolicy {
        raw.flatMap(ScrollbackRestorePolicy.init(rawValue:)) ?? defaultPolicy
    }
}
