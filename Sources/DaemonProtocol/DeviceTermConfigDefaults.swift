// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeviceTermConfigDefaults: the canonical table of `~/.config/deviceterm/config`
// keys deviceterm honors, each with its default, allowed values, and a
// one-line summary (`ConfigKeySpec`).
//
// Lives in DaemonProtocol so the App-side `Config` layer, the
// self-documenting config writer (`ConfigFile`), and the CLI's
// `deviceterm dump-config` reporter all reach the same source of truth.
// Adding a recognized key here is the architecture-checks gate's
// "default value lives in Config.swift" rule: the key + its default
// land in this table at the same time the code that reads it ships, so
// a `dump-config` report stays complete and a missing default can't
// drift between modules.

public enum DeviceTermConfigDefaults {
    /// Every recognized key, in the order the config writer emits them.
    /// The values are intentionally strings because the config file
    /// format is `key = value` text; the consumer re-parses to its
    /// richer type at the call site.
    public static let specs: [ConfigKeySpec] = [
        ConfigKeySpec(
            key: "tab-close-default",
            defaultValue: "detach",
            allowedValues: ["detach", "shutdown"],
            summary: "Action taken when closing a tab, which suppresses the Close Tab "
                + "prompt. detach closes the tab but keeps any sims it booted running; "
                + "shutdown also stops them.",
            absentBehavior: "the Close Tab prompt is shown; set detach or "
                + "shutdown to suppress it"
        ),
        ConfigKeySpec(
            key: "quit-with-sims-default",
            defaultValue: "keep",
            allowedValues: ["keep", "shutdown"],
            summary: "Action taken when quitting while deviceterm-owned sims are booted, "
                + "which suppresses the Quit prompt. keep quits leaving them running; "
                + "shutdown stops every owned booted sim first.",
            absentBehavior: "the Quit prompt is shown; set keep or shutdown "
                + "to suppress it"
        ),
        ConfigKeySpec(
            key: "simulator-app-advisory",
            defaultValue: "show",
            allowedValues: ["show", "suppress"],
            summary: "Whether to show the Simulator.app coexistence advisory when a sim "
                + "is attached while Apple's Simulator.app is also running. suppress "
                + "hides it."
        ),
        ConfigKeySpec(
            key: "auto-update",
            defaultValue: "check",
            allowedValues: ["off", "check", "download"],
            summary: "How the app handles updates via Sparkle. check (default) checks "
                + "automatically and notifies when an update is available; download also "
                + "installs it on relaunch; off disables automatic checks (the "
                + "Check for Updates… menu item still works)."
        )
    ]

    /// Recognized config keys mapped to their built-in default values.
    /// Derived from `specs` so the two never drift.
    public static let values: [String: String] =
        Dictionary(uniqueKeysWithValues: specs.map { ($0.key, $0.defaultValue) })

    /// Whether `key` is a recognized deviceterm config key. Used by
    /// `deviceterm dump-config` to flag file entries that don't match
    /// any known key as warnings.
    public static func isKnown(_ key: String) -> Bool {
        values.keys.contains(key)
    }

    /// The full spec for `key`, or nil if it isn't recognized.
    public static func spec(for key: String) -> ConfigKeySpec? {
        specs.first { $0.key == key }
    }
}
