// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

/// Truth table for the DEVICETERM_IGNORE_GHOSTTY_CONFIG dev toggle:
/// only the exact value "1" enables it, matching the other dev env
/// switches, so a stray value can't silently untheme the app.
struct GhosttyConfigOverrideTests {
    @Test("ignore-flag truth table", arguments: [
        (nil, false),
        ("1", true),
        ("0", false),
        ("", false),
        ("true", false)
    ] as [(String?, Bool)])
    func ignoresUserConfig(value: String?, expected: Bool) {
        var environment: [String: String] = [:]
        if let value {
            environment["DEVICETERM_IGNORE_GHOSTTY_CONFIG"] = value
        }
        #expect(GhosttyConfigOverride.ignoresUserConfig(environment: environment) == expected)
    }
}
