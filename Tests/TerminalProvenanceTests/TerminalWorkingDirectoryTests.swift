// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
@testable import TerminalProvenance
import Testing
#if canImport(Darwin)
import Darwin
#endif

#if canImport(Darwin)
private func snapshot(
    pid: pid_t,
    ppid: pid_t,
    euid: uid_t = 501,
    startMicros: UInt64 = 1_000,
    tty: dev_t = 42,
    foreground: pid_t = 0
) -> ProcInfo.Snapshot {
    ProcInfo.Snapshot(
        pid: pid,
        ppid: ppid,
        euid: euid,
        startMicros: startMicros,
        controllingTTYDev: tty,
        foregroundProcessGroup: foreground
    )
}

@Test
func selectsTheLoneSameUserChildOnTheAnchoredTTY() {
    let candidates = [snapshot(pid: 200, ppid: 100)]
    #expect(
        TerminalWorkingDirectory.selectShell(
            among: candidates,
            leader: 100,
            tty: 42,
            readerEUID: 501
        ) == 200
    )
}

@Test
func selectsNothingWhenThereAreNoCandidates() {
    #expect(
        TerminalWorkingDirectory.selectShell(
            among: [],
            leader: 100,
            tty: 42,
            readerEUID: 501
        ) == nil
    )
}

@Test
func selectsNothingWhenTwoChildrenBothQualify() {
    let candidates = [snapshot(pid: 200, ppid: 100), snapshot(pid: 201, ppid: 100)]
    #expect(
        TerminalWorkingDirectory.selectShell(
            among: candidates,
            leader: 100,
            tty: 42,
            readerEUID: 501
        ) == nil
    )
}

@Test
func ignoresASameUserChildThatLeftTheAnchoredTTY() {
    let candidates = [snapshot(pid: 200, ppid: 100, tty: 99)]
    #expect(
        TerminalWorkingDirectory.selectShell(
            among: candidates,
            leader: 100,
            tty: 42,
            readerEUID: 501
        ) == nil
    )
}

@Test
func ignoresAChildOwnedByAnotherUser() {
    let candidates = [snapshot(pid: 200, ppid: 100, euid: 0)]
    #expect(
        TerminalWorkingDirectory.selectShell(
            among: candidates,
            leader: 100,
            tty: 42,
            readerEUID: 501
        ) == nil
    )
}

@Test
func ignoresAGrandchildOfTheLeader() {
    let candidates = [snapshot(pid: 300, ppid: 200)]
    #expect(
        TerminalWorkingDirectory.selectShell(
            among: candidates,
            leader: 100,
            tty: 42,
            readerEUID: 501
        ) == nil
    )
}

@Test
func aProcessIsTheSameInstanceAcrossAForegroundJobChange() {
    let before = snapshot(pid: 200, ppid: 100, foreground: 200)
    let after = snapshot(pid: 200, ppid: 100, foreground: 300)
    #expect(TerminalWorkingDirectory.isSameProcessInstance(before, after))
}

@Test
func aRecycledPidIsNotTheSameInstance() {
    let before = snapshot(pid: 200, ppid: 100, startMicros: 1_000)
    let after = snapshot(pid: 200, ppid: 100, startMicros: 2_000)
    #expect(!TerminalWorkingDirectory.isSameProcessInstance(before, after))
}

@Test
func aReparentedProcessIsNotTheSameInstance() {
    let before = snapshot(pid: 200, ppid: 100)
    let after = snapshot(pid: 200, ppid: 1)
    #expect(!TerminalWorkingDirectory.isSameProcessInstance(before, after))
}

@Test
func resolvesNothingForADeadSessionLeader() {
    let facts = TerminalAnchorFacts(
        terminalSessionId: 999_999,
        sessionLeaderStartTime: 1_000,
        controllingTTYDevice: 42
    )
    #expect(TerminalWorkingDirectory.resolve(for: facts) == nil)
}

@Test
func resolvesNothingWhenTheLeaderStartTimeDoesNotMatch() {
    let leader = getsid(0)
    guard leader != -1, ProcInfo.leaderStartMicros(leader) != nil else { return }
    let facts = TerminalAnchorFacts(
        terminalSessionId: leader,
        sessionLeaderStartTime: 1,
        controllingTTYDevice: 42
    )
    #expect(TerminalWorkingDirectory.resolve(for: facts) == nil)
}

@Test
func resolvesNothingForATTYTheLeaderIsNotOn() {
    let leader = getsid(0)
    guard leader != -1, let start = ProcInfo.leaderStartMicros(leader) else { return }
    let facts = TerminalAnchorFacts(
        terminalSessionId: leader,
        sessionLeaderStartTime: start,
        controllingTTYDevice: dev_t.max
    )
    #expect(TerminalWorkingDirectory.resolve(for: facts) == nil)
}

@Test
func resolvesThisProcessDirectoryWhenItIsItsOwnSessionLeader() {
    let leader = getsid(0)
    guard leader == getpid(),
        let start = ProcInfo.leaderStartMicros(leader),
        let own = ProcInfo.snapshot(of: leader)
    else { return }
    let facts = TerminalAnchorFacts(
        terminalSessionId: leader,
        sessionLeaderStartTime: start,
        controllingTTYDevice: own.controllingTTYDev
    )
    let resolved = TerminalWorkingDirectory.resolve(for: facts)
    #expect(resolved?.hasPrefix("/") == true)
    #expect(
        resolved.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
            == URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .resolvingSymlinksInPath().path
    )
}

@Test
func readsThisProcessWorkingDirectory() {
    let read = ProcInfo.currentDirectoryPath(of: getpid())
    let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .resolvingSymlinksInPath().path
    #expect(read.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == expected)
}

@Test
func readsNoWorkingDirectoryForADeadPid() {
    #expect(ProcInfo.currentDirectoryPath(of: 999_999) == nil)
}

@Test
func readsNoWorkingDirectoryAcrossTheUIDBoundary() {
    guard getuid() != 0 else { return }
    #expect(ProcInfo.currentDirectoryPath(of: 1) == nil)
}

@Test
func listsNoChildrenForADeadPid() {
    #expect(ProcInfo.childPids(of: 999_999).isEmpty)
}

@Test
func listsASpawnedChild() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    defer {
        child.terminate()
        child.waitUntilExit()
    }
    #expect(ProcInfo.childPids(of: getpid()).contains(child.processIdentifier))
}
#endif
