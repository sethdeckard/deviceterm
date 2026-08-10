// SPDX-License-Identifier: GPL-3.0-or-later
//
// XDGPaths: the one place that resolves deviceterm's config-file
// locations from the XDG base-directory spec.
//
// Both the GUI (`ConfigFile`, `GhosttyThemeColors`) and the CLI
// (`deviceterm dump-config`) need the path to `~/.config/deviceterm/config`
// (and the borrowed `~/.config/ghostty/config`). Rather than each
// hardcoding `~/.config`, they route through here so a single rule
// (honor `$XDG_CONFIG_HOME`, fall back to `~/.config`) is defined once
// and stays consistent across processes.
//
// Lives in DaemonProtocol (Foundation-only, shared by App + CLI)
// alongside `DeviceTermConfigDefaults`, the other config source of truth.

import Foundation

public enum XDGPaths {
    /// The XDG config base directory: `$XDG_CONFIG_HOME` when set to a
    /// non-empty absolute path, else `~/.config`. Per the spec a
    /// relative or empty value is invalid and ignored.
    ///
    /// `environment` is injectable so the resolver is unit-testable
    /// without mutating the real process environment.
    public static func configHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let xdg = environment["XDG_CONFIG_HOME"] ?? ""
        if !xdg.isEmpty, (xdg as NSString).isAbsolutePath {
            return xdg
        }
        return (NSHomeDirectory() as NSString)
            .appendingPathComponent(".config")
    }

    /// Absolute path to `<config home>/deviceterm/config`.
    public static func deviceTermConfig(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        (configHome(environment: environment) as NSString)
            .appendingPathComponent("deviceterm/config")
    }

    /// Absolute path to `<config home>/deviceterm/locations`, the
    /// hand-editable list of saved locations behind Device ▸ Location.
    public static func deviceTermLocations(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        (configHome(environment: environment) as NSString)
            .appendingPathComponent("deviceterm/locations")
    }

    /// Absolute path to the borrowed `<config home>/ghostty/config`.
    public static func ghosttyConfig(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        (configHome(environment: environment) as NSString)
            .appendingPathComponent("ghostty/config")
    }
}
