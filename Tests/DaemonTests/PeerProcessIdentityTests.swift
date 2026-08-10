// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif

// PeerProcessIdentity: the kernel peer-identity resolver.
//
// The provenance matrix is driven by synthetic identities, which proves the
// policy but not the syscall plumbing. This Darwin-backed test exercises the
// real `getsockopt(LOCAL_PEERTOKEN)` + audit-token-decode path over a genuine
// accepted connection from a SEPARATE process, so a wrong socket constant, a
// mis-sized buffer, or a bad audit-token accessor is caught here.
//
// The peer is a separate `nc -U` process spawned with `POSIX_SPAWN_SETSID`, so
// it leads its own live session. That lets this test assert a real, positive
// session-leader start time; dead-leader owner resolution (where the leader
// start degrades to the 0 sentinel) is covered separately by
// `resolverKeepsOwnerIdentityWhenSessionLeaderIsDead`. (`fork()` is unavailable
// in Swift on Darwin; `posix_spawn` is the path.)

#if canImport(Darwin)
private let localPeerTokenOpt: Int32 = 0x0006  // LOCAL_PEERTOKEN, <sys/un.h>

/// Fill a `sockaddr_un.sun_path` from a Swift path. Returns false if the path
/// exceeds the fixed field.
private func fill(_ addr: inout sockaddr_un, path: String) -> Bool {
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < capacity else { return false }
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    return true
}

/// Decode the peer's (pid, pidVersion) from the raw token via a code path
/// separate from the resolver, so both fields are independently verified.
private func decodePeer(fd: Int32) -> (pid: pid_t, pidVersion: Int32)? {
    var token = audit_token_t()
    var len = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(fd, 0 /*SOL_LOCAL*/, localPeerTokenOpt, &token, &len) == 0 else {
        return nil
    }
    return (audit_token_to_pid(token), audit_token_to_pidversion(token))
}

/// Spawn `nc -U <path>` in its OWN session (`POSIX_SPAWN_SETSID`), so the peer
/// is its own live session leader. `stdinFd` becomes the child's stdin (a pipe
/// the parent holds open, so nc blocks reading and stays connected). Returns
/// the child pid, or nil on spawn failure.
private func spawnConnectingSessionLeader(path: String, stdinFd: Int32) -> pid_t? {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_adddup2(&actions, stdinFd, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup("nc"), strdup("-U"), strdup(path), nil]
    let rc = posix_spawn(&pid, "/usr/bin/nc", &actions, &attr, argv, environ)
    for arg in argv where arg != nil { free(arg) }
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attr)
    return rc == 0 ? pid : nil
}

@Test
func resolverIdentifiesSeparateSessionLeaderPeer() throws {
    let path = "/tmp/deviceterm-g15-\(getpid()).sock"
    unlink(path)
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(listener >= 0)
    defer {
        Darwin.close(listener)
        unlink(path)
    }
    var addr = sockaddr_un()
    try #require(fill(&addr, path: path))
    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bindRC = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, addrLen) }
    }
    try #require(bindRC == 0)
    try #require(listen(listener, 1) == 0)
    // Non-blocking so accept() polls with a deadline instead of hanging if the
    // child never connects.
    _ = fcntl(listener, F_SETFL, O_NONBLOCK)

    // A pipe the parent holds open as the child's stdin, so nc blocks reading
    // and stays connected until we kill it.
    var stdinPipe: [Int32] = [-1, -1]
    try #require(pipe(&stdinPipe) == 0)
    let child = try #require(spawnConnectingSessionLeader(path: path, stdinFd: stdinPipe[0]))
    Darwin.close(stdinPipe[0])  // the child holds the read end now
    defer {
        Darwin.close(stdinPipe[1])
        kill(child, SIGKILL)
        var status: Int32 = 0
        waitpid(child, &status, 0)
    }

    // Bounded accept: the child connects promptly; fail (never hang) otherwise.
    var clientFd: Int32 = -1
    for _ in 0..<500 {
        clientFd = accept(listener, nil, nil)
        if clientFd >= 0 { break }
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
            usleep(10_000)
            continue
        }
        break
    }
    try #require(clientFd >= 0)
    defer { Darwin.close(clientFd) }

    let identity = try #require(PeerProcessIdentity.resolve(fd: clientFd))
    // Cross-process: the resolved pid is the child, not the test process.
    #expect(identity.pid == child)
    #expect(identity.euid == geteuid())
    // The child led its own session, so it is its own session leader.
    #expect(identity.posixSessionId == child)
    #expect(identity.posixSessionLeaderStartTime > 0)
    // Independently decoded raw token agrees on pid AND pidVersion.
    let decoded = try #require(decodePeer(fd: clientFd))
    #expect(decoded.pid == identity.pid)
    #expect(decoded.pidVersion == identity.pidVersion)
}

/// Spawn a short-lived session leader (`/bin/sh` under `POSIX_SPAWN_SETSID`)
/// that backgrounds `nc -U <path>` and then exits, so the CONNECTING process
/// (`nc`) is left in a session whose leader is dead. `stdinFd` becomes fd 0 for
/// the shell and is inherited by the backgrounded `nc`, keeping it connected.
/// Returns the shell (leader) pid so the caller can reap it and be sure the
/// leader has exited before resolving.
private func spawnConnectorWithDeadLeader(path: String, stdinFd: Int32) -> pid_t? {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_adddup2(&actions, stdinFd, 0)
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
    var pid: pid_t = 0
    // Background nc, then let the shell reach end-of-script and exit; the
    // session leader dies while nc stays connected on the inherited stdin.
    let script = "nc -U \(path) &"
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup("sh"), strdup("-c"), strdup(script), nil]
    let rc = posix_spawn(&pid, "/bin/sh", &actions, &attr, argv, environ)
    for arg in argv where arg != nil { free(arg) }
    posix_spawn_file_actions_destroy(&actions)
    posix_spawnattr_destroy(&attr)
    return rc == 0 ? pid : nil
}

@Test
func resolverKeepsOwnerIdentityWhenSessionLeaderIsDead() throws {
    // A live peer whose POSIX session leader has exited must still resolve: the
    // owner triple `(pid, pidVersion, euid)` is leader-independent, so an
    // unavailable leader start degrades to the 0 sentinel while the owner tuple
    // is preserved. Without this the whole identity would be nil → the peer
    // `.missing` → a hard `-32001`, which would break the GUI's UDS fallback
    // (owner-arm only, since it holds no controlling tty).
    let path = "/tmp/deviceterm-deadleader-\(getpid()).sock"
    unlink(path)
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    try #require(listener >= 0)
    defer {
        Darwin.close(listener)
        unlink(path)
    }
    var addr = sockaddr_un()
    try #require(fill(&addr, path: path))
    let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
    let bindRC = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, addrLen) }
    }
    try #require(bindRC == 0)
    try #require(listen(listener, 1) == 0)
    _ = fcntl(listener, F_SETFL, O_NONBLOCK)

    var stdinPipe: [Int32] = [-1, -1]
    try #require(pipe(&stdinPipe) == 0)
    let leader = try #require(spawnConnectorWithDeadLeader(path: path, stdinFd: stdinPipe[0]))
    Darwin.close(stdinPipe[0])  // nc holds the read end now
    defer {
        Darwin.close(stdinPipe[1])  // EOF nc's stdin so it exits on its own
    }

    var clientFd: Int32 = -1
    for _ in 0..<500 {
        clientFd = accept(listener, nil, nil)
        if clientFd >= 0 { break }
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
            usleep(10_000)
            continue
        }
        break
    }
    try #require(clientFd >= 0)
    defer { Darwin.close(clientFd) }

    // Reap the leader before resolving so the lookup exercises the
    // unavailable-leader path. Retry across EINTR so a signal doesn't leave it
    // unreaped; require success so the precondition actually holds.
    var status: Int32 = 0
    var reaped = waitpid(leader, &status, 0)
    while reaped == -1, errno == EINTR { reaped = waitpid(leader, &status, 0) }
    try #require(reaped == leader)

    let identity = try #require(PeerProcessIdentity.resolve(fd: clientFd))
    // Owner triple intact and cross-checked against an independent token decode.
    let decoded = try #require(decodePeer(fd: clientFd))
    #expect(identity.pid == decoded.pid)
    #expect(identity.pidVersion == decoded.pidVersion)
    #expect(identity.euid == geteuid())
    #expect(identity.pid != leader)  // the connector is nc, not the dead leader
    // The dead-leader path was taken: leader start degrades to the 0 sentinel,
    // which can never match a real (live-captured) anchor.
    #expect(identity.posixSessionLeaderStartTime == 0)
}

@Test
func leaderStartReadsARootProcessCrossUid() {
    // A root-owned login session leader requires a cross-uid start-time lookup:
    // the user-level daemon cannot `proc_pidinfo` it, but `sysctl(KERN_PROC_PID)`
    // returns any process' start time to any user. launchd (pid 1) is a stable
    // root-owned process; on a non-root test runner a non-nil, positive result
    // exercises exactly that cross-uid lookup, which keeps a real leader start
    // time on the terminal arm.
    let start = ProcInfo.leaderStartMicros(1)
    #expect(start != nil)
    #expect((start ?? 0) > 0)
    // A pid that cannot exist resolves to nil (fail-closed / owner-arm-only).
    #expect(ProcInfo.leaderStartMicros(Int32.max) == nil)
}

@Test
func resolverReturnsNilForNonSocketDescriptor() throws {
    // A pipe read-end is not a socket, so `LOCAL_PEERTOKEN` must fail and the
    // resolver returns nil (the fail-closed signal), never a bogus identity.
    var fds: [Int32] = [-1, -1]
    try #require(pipe(&fds) == 0)
    defer {
        Darwin.close(fds[0])
        Darwin.close(fds[1])
    }
    #expect(PeerProcessIdentity.resolve(fd: fds[0]) == nil)
}
#endif
