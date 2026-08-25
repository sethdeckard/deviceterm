// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeviceFamilyClassifier: maps a CoreSimulator device-type identifier to
// the shared `DeviceFamily`. The daemon owns this: `deviceTypeIdentifier`
// is a daemon-internal CoreSimulator string; the GUI/CLI consume the
// resulting `family` (as its rawValue) off the wire.

import DaemonProtocol

public enum DeviceFamilyClassifier {
    /// Map a `deviceTypeIdentifier` like
    /// `com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-11-46mm`
    /// to a `DeviceFamily`. Match is case-insensitive and substring-based
    /// so it survives Apple's frequent device-name churn. Order matters:
    /// `watch` and `pad` before `phone`, `tv` last.
    public static func classify(_ deviceTypeIdentifier: String) -> DeviceFamily {
        let identifier = deviceTypeIdentifier.lowercased()
        if identifier.contains("watch") { return .watch }
        if identifier.contains("ipad") { return .pad }
        if identifier.contains("iphone") || identifier.contains("ipod") { return .phone }
        if identifier.contains("apple-tv") || identifier.contains("appletv") { return .tv }
        return .unknown
    }
}
