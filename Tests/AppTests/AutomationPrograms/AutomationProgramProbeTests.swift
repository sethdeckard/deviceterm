// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import TerminalProvenance
import Testing

// AutomationProgramProbeTests: composing a terminal reading into what the
// terminal is doing.
//
// The rule that identifies the shell lives in `TerminalShellIdentity` and is
// tested there, including the login-shaped tree. What is tested here is the
// composition, and specifically that a tab with no terminal to ask reports
// `unknown` rather than `idle`. Supervision types into an idle terminal, so
// the difference is whether a program deviceterm cannot see gets a command
// injected into it.

private let tab = TabID(value: 1)

private func probe(
    identity: (foregroundPid: Int32, ttyName: String)?,
    state: TerminalForegroundState
) -> AutomationProgramProbe {
    AutomationProgramProbe(
        terminalIdentity: { _ in identity },
        foregroundState: { _, _ in state }
    )
}

@Test("a foreground program is reported with its pid")
@MainActor
func reportsTheRunningProgram() {
    #expect(
        probe(identity: (910, "/dev/ttys001"), state: .running(910)).state(ofTab: tab)
            == .running(910)
    )
}

@Test("a terminal at its shell prompt reports idle")
@MainActor
func reportsIdleForTheShellPrompt() {
    #expect(probe(identity: (900, "/dev/ttys001"), state: .idle).state(ofTab: tab) == .idle)
}

/// No terminal to ask is an unestablished state, not an idle one. Reporting
/// idle here would let supervision type into a tab it knows nothing about.
@Test("no terminal to ask reports unknown, not idle")
@MainActor
func reportsUnknownWithoutATerminal() {
    #expect(probe(identity: nil, state: .idle).state(ofTab: tab) == .unknown)
}

@Test("an unreadable foreground process reports unknown")
@MainActor
func reportsUnknownForAnUnreadableForeground() {
    #expect(probe(identity: (910, "/dev/ttys001"), state: .unknown).state(ofTab: tab) == .unknown)
}
