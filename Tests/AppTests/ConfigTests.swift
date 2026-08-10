// SPDX-License-Identifier: GPL-3.0-or-later
//
// Canonical defaults coverage. The architecture-checks gate
// requires every new ~/.config/deviceterm/config key to have a default
// recorded in Config.swift. This test pins them.

@testable import App
import Testing

@Test
func canonicalDefaultsCoverCloseKeys() {
    #expect(Config.defaultValue(for: "tab-close-default") == "detach")
    #expect(Config.defaultValue(for: "quit-with-sims-default") == "keep")
}

@Test
func canonicalDefaultsCoverAdvisoryKey() {
    // The Simulator.app advisory's "Don't show again" state lives in
    // the config file (not UserDefaults); default shows the advisory.
    #expect(Config.defaultValue(for: "simulator-app-advisory") == "show")
}

@Test
func canonicalDefaultsCoverAutoUpdateKey() {
    #expect(Config.defaultValue(for: "auto-update") == "check")
}

@Test
func unknownKeyHasNoDefault() {
    #expect(Config.defaultValue(for: "no-such-key") == nil)
}

@Test
func autoUpdatePolicyResolvesFromConfigValues() {
    #expect(AutoUpdatePolicy.resolve("off") == .off)
    #expect(AutoUpdatePolicy.resolve("check") == .check)
    #expect(AutoUpdatePolicy.resolve("download") == .download)
    // nil / unknown → the default (check).
    #expect(AutoUpdatePolicy.resolve(nil) == .check)
    #expect(AutoUpdatePolicy.resolve("bogus") == .check)
    #expect(AutoUpdatePolicy.defaultPolicy == .check)
}

@Test
func autoUpdatePolicyMapsToSparkleFlags() {
    #expect(AutoUpdatePolicy.off.automaticallyChecksForUpdates == false)
    #expect(AutoUpdatePolicy.check.automaticallyChecksForUpdates == true)
    #expect(AutoUpdatePolicy.check.automaticallyDownloadsUpdates == false)
    #expect(AutoUpdatePolicy.download.automaticallyDownloadsUpdates == true)
}
