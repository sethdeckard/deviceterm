// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import TerminalProvenance
import Testing
#if canImport(Darwin)
import Darwin
#endif

// Tests may run without a controlling terminal, so the positive case reads this
// process against its own `e_tdev` rather than through a tty path.

#if canImport(Darwin)
@Test
func namesAProcessOnItsOwnControllingTerminal() throws {
    let info = try #require(ProcInfo.bsdInfo(of: getpid()))
    let name = try #require(
        TerminalForegroundProcess.name(of: getpid(), controlledBy: dev_t(bitPattern: info.e_tdev))
    )
    #expect(!name.isEmpty)
    #expect(ProcessInfo.processInfo.processName.hasPrefix(name))
}

@Test
func namesNothingForAProcessOnAnotherTerminal() throws {
    let info = try #require(ProcInfo.bsdInfo(of: getpid()))
    let other = dev_t(bitPattern: info.e_tdev) &+ 1
    #expect(TerminalForegroundProcess.name(of: getpid(), controlledBy: other) == nil)
}

@Test("foreground process name fails closed", arguments: [
    (getpid(), "/etc/hosts"),
    (getpid(), "/dev/null"),
    (getpid(), "/nope/not/here"),
    (999_999, "/dev/null")
])
func foregroundProcessNameFailsClosed(pid: pid_t, ttyName: String) {
    #expect(TerminalForegroundProcess.name(foregroundPid: pid, ttyName: ttyName) == nil)
}
#endif
