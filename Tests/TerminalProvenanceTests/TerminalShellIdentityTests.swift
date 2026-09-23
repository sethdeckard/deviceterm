// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import TerminalProvenance
import Testing
#if canImport(Darwin)
import Darwin

// TerminalShellIdentityTests: which process in a terminal is its shell.
//
// Live-process checks for what the kernel actually reports, plus synthetic
// login-shell trees and foreground-state cases for the shapes a test process
// cannot produce on its own.
//
// The rule this protects is that the session leader is not the shell. For a
// login-shell terminal the leader is a root-owned `/usr/bin/login` and the
// shell is its child, so anything that decides "is this terminal busy" by
// comparing a foreground pid against `getsid` calls an idle terminal busy
// and never sees a program exit.

private func snapshot(
    pid: pid_t,
    ppid: pid_t,
    euid: uid_t = 501,
    tty: dev_t = 42
) -> ProcInfo.Snapshot {
    ProcInfo.Snapshot(
        pid: pid,
        ppid: ppid,
        euid: euid,
        startMicros: 1_000,
        controllingTTYDev: tty,
        foregroundProcessGroup: 0
    )
}

/// This process' own controlling tty device, which is 0 when it has none.
/// Either value is fine: what matters is that the same number is used for
/// the leader and the candidates, as a real terminal does.
private func ownTTYDevice() -> dev_t {
    ProcInfo.snapshot(of: getpid())?.controllingTTYDev ?? 0
}

/// A terminal spawned without `login` has the shell as its own session
/// leader, and the leader branch is what answers there.
@Test
func resolvesTheLeaderWhenItIsASameUserProcessOnThisTTY() {
    #expect(
        TerminalShellIdentity.resolve(
            leader: getpid(),
            tty: ownTTYDevice(),
            readerEUID: geteuid()
        ) == getpid()
    )
}

/// The same live process on a tty it is not on resolves to nothing rather
/// than to itself, which is the fail-closed half of the rule.
@Test
func resolvesNothingForALeaderOnAnotherTTY() {
    let foreign = ownTTYDevice() &+ 1
    #expect(
        TerminalShellIdentity.resolve(
            leader: getpid(),
            tty: foreign,
            readerEUID: geteuid()
        ) == nil
    )
}

/// A euid that owns nothing here matches neither the leader nor any child,
/// so an unreadable tree answers nothing instead of guessing.
@Test
func resolvesNothingAcrossTheUIDBoundary() {
    #expect(
        TerminalShellIdentity.resolve(
            leader: getpid(),
            tty: ownTTYDevice(),
            readerEUID: geteuid() &+ 1
        ) == nil
    )
}

/// A login-shell terminal: the session leader is a root-owned `/usr/bin/login`
/// and the shell is its same-euid child. The whole rule exists for this shape,
/// so it is exercised directly rather than inferred from live pids.
@Test
func resolvesTheShellBeneathARootOwnedLoginLeader() {
    let tty: dev_t = 42
    let leader = snapshot(pid: 100, ppid: 1, euid: 0, tty: tty)
    let shell = snapshot(pid: 200, ppid: 100, euid: 501, tty: tty)
    let resolved = TerminalShellIdentity.resolve(
        leader: 100,
        tty: tty,
        readerEUID: 501,
        snapshot: { [100: leader, 200: shell][$0] },
        children: { $0 == 100 ? [200] : [] }
    )
    #expect(resolved == 200)
}

/// The same tree, one step further out: the foreground process is a child of
/// the shell, so the terminal is running something rather than idle. This is
/// the login to shell to program distinction the supervision rule turns on.
@Test
func tellsAForegroundProgramFromTheShellBeneathLogin() {
    #expect(TerminalShellIdentity.state(foregroundPid: 200, shell: 200) == .idle)
    #expect(TerminalShellIdentity.state(foregroundPid: 300, shell: 200) == .running(300))
}

/// An unreadable or ambiguous tree is not an idle terminal. Collapsing the
/// two would let supervision type into a foreground process it cannot see,
/// a `sudo` running as root being the ordinary way to produce one.
@Test
func reportsUnknownRatherThanIdleWhenTheShellCannotBeResolved() {
    #expect(TerminalShellIdentity.state(foregroundPid: 300, shell: nil) == .unknown)
}

/// A process can inherit another process' session, so a pid differing from
/// its session id establishes nothing about what a terminal is running.
/// Anything inferring "a program is running" from
/// `foregroundPid != getsid(foregroundPid)` is reading noise.
@Test
func aProcessIsNotGenerallyItsOwnSessionLeader() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    defer {
        child.terminate()
        child.waitUntilExit()
    }
    let pid = child.processIdentifier
    // The child inherits this process' session, so its session leader is
    // some other process entirely, exactly as a shell's is `login`.
    #expect(getsid(pid) != pid)
    #expect(ProcInfo.childPids(of: getpid()).contains(pid))
}
#endif
