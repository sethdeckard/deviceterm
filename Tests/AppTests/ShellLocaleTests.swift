// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Testing

// ShellLocale derives the POSIX LANG injected into the spawned login
// shell when a LaunchServices-launched .app carries no locale.

@Test
func buildsPosixLangFromInstalledLanguageAndRegion() {
    #expect(ShellLocale.posixLang(language: "en", region: "US", isInstalled: { _ in true }) == "en_US.UTF-8")
    #expect(ShellLocale.posixLang(language: "fr", region: "CA", isInstalled: { _ in true }) == "fr_CA.UTF-8")
}

@Test
func fallsBackWhenTheRegionComboIsNotInstalled() {
    // English UI + Germany region ⇒ en_DE.UTF-8, which macOS doesn't ship.
    // It must not be handed to the shell; fall back to a valid locale.
    #expect(ShellLocale.posixLang(language: "en", region: "DE", isInstalled: { _ in false }) == "en_US.UTF-8")
}

@Test("missing or empty parts fall back to en_US.UTF-8", arguments: [
    (String?.none, String?.some("US")),
    (.some("en"), .none),
    (.some(""), .some("US")),
    (.some("en"), .some("")),
    (.none, .none)
])
func fallsBackWhenIncomplete(language: String?, region: String?) {
    // Incomplete parts never form a candidate, so the probe is irrelevant.
    #expect(ShellLocale.posixLang(language: language, region: region, isInstalled: { _ in true }) == "en_US.UTF-8")
}

@Test
func injectsDerivedLangWhenProcessHasNone() {
    #expect(
        ShellLocale.injectedLang(existing: nil, language: "en", region: "US", isInstalled: { _ in true })
            == "en_US.UTF-8"
    )
    #expect(
        ShellLocale.injectedLang(existing: "", language: "de", region: "DE", isInstalled: { _ in true })
            == "de_DE.UTF-8"
    )
}

@Test
func leavesAnExistingLangUntouched() {
    // A user/terminal-set locale must win, so return nil and leave it alone.
    #expect(
        ShellLocale.injectedLang(
            existing: "en_GB.UTF-8", language: "en", region: "US", isInstalled: { _ in true }
        ) == nil
    )
}

@Test
func realProbeAcceptsEnUSAndRejectsGibberish() {
    // The production probe: en_US.UTF-8 ships on every macOS; a bogus
    // name never resolves. Guards the newlocale wiring itself.
    #expect(ShellLocale.isInstalled("en_US.UTF-8"))
    #expect(!ShellLocale.isInstalled("zz_ZZ.NOTACHARSET"))
}
