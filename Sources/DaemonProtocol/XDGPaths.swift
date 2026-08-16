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

    /// The XDG cache base directory: `$XDG_CACHE_HOME` when set to a
    /// non-empty absolute path, else `~/.cache`. Same validity rule as
    /// `configHome`: a relative or empty value is invalid and ignored.
    public static func cacheHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let xdg = environment["XDG_CACHE_HOME"] ?? ""
        if !xdg.isEmpty, (xdg as NSString).isAbsolutePath {
            return xdg
        }
        return (NSHomeDirectory() as NSString)
            .appendingPathComponent(".cache")
    }

    /// Absolute path to `<cache home>/deviceterm/welcome-seen`, the
    /// record of which welcome windows have already been shown.
    ///
    /// Cache rather than config because it is written by the app, not
    /// the user: the config file is hand-edited and should stay
    /// preferences only. Deleting the cache re-shows each welcome once,
    /// which is the documented cost of putting it here rather than under
    /// `$XDG_STATE_HOME`.
    public static func deviceTermWelcomeSeen(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        (cacheHome(environment: environment) as NSString)
            .appendingPathComponent("deviceterm/welcome-seen")
    }

    /// Absolute path to the borrowed `<config home>/ghostty/config`.
    public static func ghosttyConfig(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        (configHome(environment: environment) as NSString)
            .appendingPathComponent("ghostty/config")
    }
}
