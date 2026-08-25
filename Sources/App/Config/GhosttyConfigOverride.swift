// SPDX-License-Identifier: GPL-3.0-or-later
//
// GhosttyConfigOverride: a dev toggle that makes the app ignore the
// user's ghostty config entirely so it renders in its default theme.
// Gated on DEVICETERM_IGNORE_GHOSTTY_CONFIG=1; `make run-default` sets
// it for a launch. Both readers of the config honor the toggle:
// libghostty's wholesale load at runtime bootstrap (skipped via the
// `loadUserConfig` parameter threaded through `GhosttyTerminalSurface`)
// and `GhosttyThemeColors`' chrome-tint side-read (returns nil, so the
// chrome falls back to system colors).

import Foundation

enum GhosttyConfigOverride {
    static func ignoresUserConfig(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["DEVICETERM_IGNORE_GHOSTTY_CONFIG"] == "1"
    }
}
