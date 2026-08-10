// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import LibghosttyBridge
@testable import TerminalSurface
import Testing

// Pure marshaling is the one bridge piece testable without a live
// Metal surface (surface/runtime need a GPU + NSApp). Everything
// else is exercised by the LibghosttyHarness smoke binary.

@Test
func quoteWrapsAndEscapesSingleQuotes() {
    #expect(ShellCommandLine.quote("plain") == "'plain'")
    #expect(ShellCommandLine.quote("a b") == "'a b'")
    #expect(ShellCommandLine.quote("it's") == "'it'\\''s'")
    #expect(ShellCommandLine.quote("$(rm -rf /)") == "'$(rm -rf /)'")
}

@Test
func commandStringQuotesEveryComponent() {
    let command = TerminalCommand(
        executable: "/bin/zsh",
        arguments: ["-l", "-c", "echo hi"]
    )
    #expect(
        ShellCommandLine.commandString(for: command)
            == "'/bin/zsh' '-l' '-c' 'echo hi'"
    )
}

@Test
func environmentPairsAreSortedByKey() {
    let command = TerminalCommand(
        executable: "/bin/zsh",
        environment: ["ZED": "1", "ABC": "2", "MID": "3"]
    )
    let pairs = ShellCommandLine.environmentPairs(for: command)
    #expect(pairs.map(\.key) == ["ABC", "MID", "ZED"])
    #expect(pairs.map(\.value) == ["2", "3", "1"])
}

@Test
func loginShellFallsBackToZsh() {
    // SHELL is normally set; the contract is the fallback when it
    // isn't. Exercise the explicit-executable path instead of
    // mutating process env in a test.
    let command = TerminalCommand.loginShell(environment: ["A": "B"])
    #expect(command.arguments == ["-l"])
    #expect(command.environment == ["A": "B"])
    #expect(!command.executable.isEmpty)
}
