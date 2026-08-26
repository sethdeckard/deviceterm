// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

/// SettingsEditorCommand: the argv tokens typed into the editor tab's
/// shell. The editor token stays unquoted (shell-expanded); the path is
/// POSIX single-quoted.
struct SettingsEditorCommandTests {
    @Test
    func wrapsEditorFallbackAndQuotesPath() {
        let tokens = SettingsEditorCommand.tokens(
            forConfigPath: "/Users/x/.config/deviceterm/config"
        )
        #expect(tokens == [
            "${VISUAL:-${EDITOR:-vi}}",
            "'/Users/x/.config/deviceterm/config'"
        ])
    }

    @Test
    func singleQuotesPathContainingSpace() {
        let tokens = SettingsEditorCommand.tokens(forConfigPath: "/Users/a b/config")
        #expect(tokens.last == "'/Users/a b/config'")
    }

    @Test
    func escapesEmbeddedSingleQuote() {
        let tokens = SettingsEditorCommand.tokens(forConfigPath: "/Users/o'brien/config")
        #expect(tokens.last == "'/Users/o'\\''brien/config'")
    }
}
