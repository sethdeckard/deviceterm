// SPDX-License-Identifier: GPL-3.0-or-later
//
// Config: the canonical defaults table for `~/.config/deviceterm/config`.
//
// The defaults themselves live in `DeviceTermConfigDefaults` (in
// DaemonProtocol) so the App-side `Config` layer and the CLI's
// `deviceterm dump-config` reporter share one source of truth. This
// file is the App-side facade: it re-exposes the shared map and
// provides the `defaultValue(for:)` lookup callers paired with a
// `ConfigFile` read.
//
// The keys here are exactly the DeviceTerm-only preference keys. A
// DeviceTerm config-file value may override its matching built-in
// default; terminal presentation and terminal-local key bindings remain
// a separate Ghostty configuration domain loaded by libghostty. A future
// preferences surface must preserve that split rather than introduce a
// resolver spanning both domains.

import DaemonProtocol
import Foundation

enum Config {
    /// Canonical defaults for every `~/.config/deviceterm/config` key
    /// the GUI honors. Sourced from `DeviceTermConfigDefaults.values`
    /// so the App + CLI never disagree.
    static let defaults: [String: String] = DeviceTermConfigDefaults.values

    /// The default for `key`, or nil if `key` is not a recognized
    /// preference. Callers usually pair this with a `ConfigFile`
    /// read: `file.value(forKey:) ?? Config.defaultValue(for:)`.
    static func defaultValue(for key: String) -> String? {
        defaults[key]
    }
}
