// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
@testable import DeviceTermCLI
import Foundation
import Testing

// `deviceterm automation status` / `restart`: parser and formatter.
//
// The parser tests matter beyond the usual rule here. These verbs are the
// CLI's whole automation-program surface, and the design turns on them
// taking no command, no path and no tab, so what they refuse is as much
// the contract as what they accept.

// MARK: - Parser

@Test
func parseAutomationStatus() {
    #expect(CLICommands.parse(["deviceterm", "automation", "status"]) == .automationStatus)
}

@Test
func parseAutomationRestartWithoutAName() {
    #expect(
        CLICommands.parse(["deviceterm", "automation", "restart"]) == .automationRestart(name: nil)
    )
}

@Test
func parseAutomationRestartWithAName() {
    #expect(
        CLICommands.parse(["deviceterm", "automation", "restart", "--name", "clock"])
            == .automationRestart(name: "clock")
    )
}

@Test
func automationAloneReportsItsSubVerbs() {
    guard case let .usage(message) = CLICommands.parse(["deviceterm", "automation"]) else {
        Issue.record("expected usage")
        return
    }
    let text = message ?? ""
    #expect(text.contains("status"))
    #expect(text.contains("restart"))
}

/// The verbs deliberately accept nothing that could name what to run.
@Test("automation verbs refuse arguments that would name a command", arguments: [
    ["deviceterm", "automation", "restart", "--command", "rm -rf /"],
    ["deviceterm", "automation", "restart", "--cwd", "/tmp"],
    ["deviceterm", "automation", "status", "--name", "clock"],
    ["deviceterm", "automation", "status", "extra"]
])
func refusesArgumentsThatWouldNameACommand(argv: [String]) {
    guard case .usage = CLICommands.parse(argv) else {
        Issue.record("expected usage refusal for \(argv)")
        return
    }
}

// MARK: - Formatter

@Test
func formatsNothingConfigured() {
    #expect(formatAutomationPrograms([]) == "no automation programs configured")
}

@Test
func formatsARunningProgram() {
    let line = formatAutomationPrograms([
        AutomationProgramStatus(
            name: "clock",
            state: .running,
            pid: 910,
            tabId: "T1",
            restarts: 2
        )
    ])
    #expect(line == "running clock pid=910 restarts=2 tab=T1")
}

/// A healthy program with nothing to report renders as one short line, and
/// a failed one carries its reason.
@Test
func formatsAFailedProgram() {
    let line = formatAutomationPrograms([
        AutomationProgramStatus(name: "crasher", state: .failed, lastError: "gave up")
    ])
    #expect(line == "failed crasher (gave up)")
}

@Test
func formatsOneLinePerProgramInOrder() {
    let lines = formatAutomationPrograms([
        AutomationProgramStatus(name: "first", state: .running),
        AutomationProgramStatus(name: "second", state: .stopped)
    ])
    #expect(lines == "running first\nstopped second")
}
