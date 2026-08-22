// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import DaemonTestSupport
import Foundation
import Testing

// MARK: - Capability

@Test
func capabilityRandomProducesStandardLength() throws {
    let cap = try Capability.random()
    #expect(cap.bytes.count == Capability.standardByteCount)
}

@Test
func capabilityRandomIsActuallyRandom() throws {
    // 32 bytes generated from SecRandomCopyBytes, so the probability
    // of two consecutive draws matching is negligible. If this
    // ever fails the RNG is broken.
    let first = try Capability.random()
    let second = try Capability.random()
    #expect(first != second)
}

@Test
func capabilityTokenRoundtripsThroughBase64() throws {
    let original = try Capability.random()
    let decoded = try #require(Capability(token: original.token))
    #expect(decoded == original)
}

@Test
func capabilityInitFromMalformedTokenReturnsNil() {
    #expect(Capability(token: "not-valid-base64!@#$") == nil)
}

@Test
func capabilityEqualityRejectsDifferentLengths() {
    let short = Capability(bytes: Data([1, 2, 3]))
    let long = Capability(bytes: Data([1, 2, 3, 0]))
    #expect(short != long)
}

@Test
func capabilityEqualityIsBytewiseExact() {
    let baseline = Capability(bytes: Data([0x01, 0x02, 0x03, 0x04]))
    let same = Capability(bytes: Data([0x01, 0x02, 0x03, 0x04]))
    let oneOff = Capability(bytes: Data([0x01, 0x02, 0x03, 0x05]))
    #expect(baseline == same)
    #expect(baseline != oneOff)
}

// MARK: - SessionManager

@Test
func createSessionMintsUniqueIdAndCapability() async throws {
    let manager = SessionManager()
    let alpha = try await manager.createSession(label: "alpha")
    let beta = try await manager.createSession(label: "beta")
    #expect(alpha.state.id != beta.state.id)
    #expect(alpha.capability != beta.capability)
    #expect(alpha.state.label == "alpha")
    #expect(beta.state.label == "beta")
}

@Test
func createSessionAcceptsNilLabel() async throws {
    let manager = SessionManager()
    let state = try await manager.makeSessionState(label: nil)
    #expect(state.label == nil)
}

@Test
func validateAcceptsCorrectCredentials() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)
    let validated = try await manager.validate(
        sessionId: created.state.id,
        capability: created.capability
    )
    #expect(validated == created.state)
}

@Test
func validateRejectsUnknownSession() async throws {
    let manager = SessionManager()
    let bogusId = UUID()
    let bogusCap = try Capability.random()
    await #expect(throws: SessionError.notFound(sessionId: bogusId)) {
        _ = try await manager.validate(sessionId: bogusId, capability: bogusCap)
    }
}

@Test
func validateRejectsWrongCapability() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)
    let wrongCap = try Capability.random()
    await #expect(throws: SessionError.invalidCapability(sessionId: created.state.id)) {
        _ = try await manager.validate(sessionId: created.state.id, capability: wrongCap)
    }
}

@Test
func closeRequiresMatchingCapability() async throws {
    let manager = SessionManager()
    let alpha = try await manager.createSession(label: nil)
    let beta = try await manager.createSession(label: nil)
    // Trying to close alpha with beta's cap must fail; alpha must
    // remain in the session map.
    await #expect(throws: SessionError.invalidCapability(sessionId: alpha.state.id)) {
        try await manager.closeSession(sessionId: alpha.state.id, capability: beta.capability)
    }
    let stillAlive = try await manager.validate(
        sessionId: alpha.state.id,
        capability: alpha.capability
    )
    #expect(stillAlive == alpha.state)
}

@Test
func closeRemovesSession() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)
    try await manager.closeSession(sessionId: created.state.id, capability: created.capability)
    await #expect(throws: SessionError.notFound(sessionId: created.state.id)) {
        _ = try await manager.validate(
            sessionId: created.state.id,
            capability: created.capability
        )
    }
}

@Test
func allSessionsReturnsCreationOrder() async throws {
    // Inject a deterministic clock so we don't depend on real-time
    // scheduling for the order assertion.
    let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
    let times = [baseDate, baseDate.addingTimeInterval(1), baseDate.addingTimeInterval(2)]
    let index = ManagedAtomicInt()
    let manager = SessionManager(
        now: {
        let position = index.incrementAndGet() - 1
        return times[min(position, times.count - 1)]
        }
        )
    let first = try await manager.makeSessionState(label: "first")
    let second = try await manager.makeSessionState(label: "second")
    let third = try await manager.makeSessionState(label: "third")
    let listed = await manager.allSessions()
    #expect(listed.map(\.id) == [first.id, second.id, third.id])
}

@Test
func sessionCountTracksMutations() async throws {
    let manager = SessionManager()
    let initial = await manager.sessionCount
    #expect(initial == 0)
    let created = try await manager.createSession(label: nil)
    let state = created.state
    let afterCreate = await manager.sessionCount
    #expect(afterCreate == 1)
    try await manager.closeSession(sessionId: state.id, capability: created.capability)
    let afterClose = await manager.sessionCount
    #expect(afterClose == 0)
}

// MARK: - isAlive (orphan-adoption liveness predicate)

@Test
func isAliveReturnsFalseForUnknownSession() async {
    // Membership check first: a session never created (or already
    // closed) is dead regardless of pid. Pins the lower bound for
    // the dedup gate's "no record exists" path.
    let manager = SessionManager()
    let isAlive = await manager.isAlive(UUID())
    #expect(isAlive == false)
}

@Test
func isAliveAssumesAliveWhenOwnerPidMissing() async throws {
    // CLI-minted sessions and tests don't carry a pid; the safe
    // default is "assume alive" so the dedup falls through to the
    // pre-pid behavior (cross-session reject) instead of silently
    // adopting on a missing field.
    let manager = SessionManager()
    let state = try await manager.makeSessionState(label: nil)
    #expect(state.ownerPID == nil)
    let isAlive = await manager.isAlive(state.id)
    #expect(isAlive == true)
}

@Test
func isAliveAssumesAliveForNonPositivePid() async throws {
    // pid <= 0 are reserved (process groups, errors, init) and are
    // never a real GUI process. Treat as "assume alive" rather than
    // failing closed on a malformed input. That keeps the door closed
    // against accidental orphan-adoption on garbage data.
    let manager = SessionManager()
    let state = try await manager.makeSessionState(
        label: nil,
        ownerPID: 0
    )
    let isAlive = await manager.isAlive(state.id)
    #expect(isAlive == true)
}

@Test
func isAliveReturnsTrueForCurrentProcess() async throws {
    // The test process itself is alive; kill(getpid(), 0) succeeds.
    // Pins the "real pid + alive" branch end-to-end.
    let manager = SessionManager()
    let state = try await manager.makeSessionState(
        label: nil,
        ownerPID: getpid()
    )
    let isAlive = await manager.isAlive(state.id)
    #expect(isAlive == true)
}

@Test
func isAliveReturnsFalseForExitedProcess() async throws {
    // Spawn a child that exits immediately, wait for it, then use
    // its (now-reaped) pid as a known-dead one. After `waitpid` the
    // kernel releases the pid, so kill(pid, 0) returns -1 with
    // ESRCH, the signal `isAlive` keys on to allow orphan adoption.
    let manager = SessionManager()
    let pid = try spawnDeadChildAndReap()
    let state = try await manager.makeSessionState(
        label: nil,
        ownerPID: pid
    )
    let isAlive = await manager.isAlive(state.id)
    #expect(isAlive == false)
}

@Test
func createSessionInitialProtectedSeedsFlagAtCreate() async throws {
    // `initialProtected: true` must make the session protected the instant
    // it exists: a terminal joining a protected tab is never observable
    // as unprotected. Both the direct reader and the visibility filter agree.
    let manager = SessionManager()
    let priv = try await manager.makeSessionState(label: nil, initialProtected: true)
    #expect(await manager.isProtected(priv.id) == true)
    // Hidden from an unauthenticated (nil) caller; visible to itself.
    let toStranger = await manager.sessions(visibleTo: nil).map(\.id)
    #expect(!toStranger.contains(priv.id))
    let toSelf = await manager.sessions(visibleTo: priv.id).map(\.id)
    #expect(toSelf.contains(priv.id))
}

@Test
func setProtectedBatchAppliesToTheWholeSetAllOrNone() async throws {
    // The batch flips every listed session atomically and applies the
    // desired absolute state (idempotent); a later unprotected batch for a
    // subset frees only those, leaving the rest protected.
    let manager = SessionManager()
    let alpha = try await manager.makeSessionState(label: nil)
    let beta = try await manager.makeSessionState(label: nil)
    let gamma = try await manager.makeSessionState(label: nil)
    try await manager.setProtectedBatch(
        sessionIds: [alpha.id, beta.id, gamma.id],
        isProtected: true,
        revision: 1,
        epoch: 1
    )
    #expect(await manager.isProtected(alpha.id))
    #expect(await manager.isProtected(beta.id))
    #expect(await manager.isProtected(gamma.id))
    try await manager.setProtectedBatch(
        sessionIds: [alpha.id, beta.id],
        isProtected: false,
        revision: 2,
        epoch: 1
    )
    #expect(await manager.isProtected(alpha.id) == false)
    #expect(await manager.isProtected(beta.id) == false)
    #expect(await manager.isProtected(gamma.id) == true)
}

@Test
func setProtectedBatchStaleRevisionIsIgnored() async throws {
    // Old write arriving after a newer one: the daemon orders by
    // (epoch, revision) and rejects the stale batch WITHOUT mutating, so
    // last-write-wins holds regardless of arrival order.
    let manager = SessionManager()
    let session = try await manager.makeSessionState(label: nil)
    let newer = try await manager.setProtectedBatch(
        sessionIds: [session.id], isProtected: true, revision: 5, epoch: 1
    )
    #expect(newer.applied)
    #expect(await manager.isProtected(session.id))
    // An unprotected write that raced in late with a lower revision (same epoch).
    let older = try await manager.setProtectedBatch(
        sessionIds: [session.id], isProtected: false, revision: 3, epoch: 1
    )
    #expect(older.applied == false)             // rejected as stale
    #expect(await manager.isProtected(session.id)) // still protected; no mutation
}

@Test
func setProtectedBatchHigherEpochDominatesLowerRevision() async throws {
    // XPC reconnect / GUI restart: a fresh connection's higher epoch wins
    // even with a LOWER revision, and a late request from the OLD
    // connection loses however high its revision. This is exactly why the
    // key is (epoch, revision) and not a bare revision.
    let manager = SessionManager()
    let session = try await manager.makeSessionState(label: nil)
    // Old connection set it unprotected at a high revision.
    _ = try await manager.setProtectedBatch(
        sessionIds: [session.id], isProtected: false, revision: 9, epoch: 1
    )
    // New connection (higher epoch), revision 1: dominates.
    let fresh = try await manager.setProtectedBatch(
        sessionIds: [session.id], isProtected: true, revision: 1, epoch: 2
    )
    #expect(fresh.applied)
    #expect(await manager.isProtected(session.id))
    // A straggler from the OLD connection (epoch 1) arrives with an even
    // higher revision: still loses to the newer epoch.
    let late = try await manager.setProtectedBatch(
        sessionIds: [session.id], isProtected: false, revision: 99, epoch: 1
    )
    #expect(late.applied == false)
    #expect(await manager.isProtected(session.id)) // stays protected
}

@Test
func setProtectedBatchStaleForAnyMemberRejectsWholeBatch() async throws {
    // All-or-none dominance: if the key fails to dominate even ONE target
    // session, the whole batch is stale and nothing mutates; a tab's
    // sessions never split.
    let manager = SessionManager()
    let alpha = try await manager.makeSessionState(label: nil)
    let beta = try await manager.makeSessionState(label: nil)
    // beta already at revision 5; alpha untouched.
    _ = try await manager.setProtectedBatch(
        sessionIds: [beta.id], isProtected: true, revision: 5, epoch: 1
    )
    // Batch over both at revision 3: dominates alpha (unset) but not beta.
    let result = try await manager.setProtectedBatch(
        sessionIds: [alpha.id, beta.id], isProtected: true, revision: 3, epoch: 1
    )
    #expect(result.applied == false)
    #expect(await manager.isProtected(alpha.id) == false) // not partially applied
    #expect(await manager.isProtected(beta.id))            // unchanged
}

@Test
func protectionSnapshotFencesOutDelayedOlderWrite() async throws {
    // The fence is the point of the snapshot: taking it at revision 5
    // advances the session's ordering key, so a delayed OLDER write
    // (revision 3) subsequently loses; the "authoritative" read can't be
    // obsolete by the time the GUI acts on it.
    let manager = SessionManager()
    let session = try await manager.makeSessionState(label: nil)
    let snap = await manager.protectionSnapshot(sessionIds: [session.id], revision: 5, epoch: 1)
    #expect(snap.fenced)
    #expect(snap.sessions.first?.state == .unprotectedState)
    let delayedOlder = try await manager.setProtectedBatch(
        sessionIds: [session.id], isProtected: true, revision: 3, epoch: 1
    )
    #expect(delayedOlder.applied == false)           // fenced out
    #expect(await manager.isProtected(session.id) == false) // unchanged
}

@Test
func protectionSnapshotUnfencedWhenNewerAuthorityExists() async throws {
    // A snapshot whose key can't dominate an existing newer authority is
    // NOT fenced: it still reports the current state, but the GUI must
    // treat it as unresolved (it may be about to change).
    let manager = SessionManager()
    let session = try await manager.makeSessionState(label: nil)
    _ = try await manager.setProtectedBatch(
        sessionIds: [session.id], isProtected: true, revision: 10, epoch: 1
    )
    let snap = await manager.protectionSnapshot(sessionIds: [session.id], revision: 5, epoch: 1)
    #expect(snap.fenced == false)
    #expect(snap.sessions.first?.state == .protectedState)
}

@Test
func protectionSnapshotReportsMissingSession() async throws {
    // An unknown id is reported explicitly as `.missing` (so the GUI sees a
    // membership change) and does not block fencing the live sessions.
    let manager = SessionManager()
    let session = try await manager.makeSessionState(label: nil)
    let ghost = UUID()
    let snap = await manager.protectionSnapshot(
        sessionIds: [session.id, ghost], revision: 1, epoch: 1
    )
    #expect(snap.fenced)
    let byId = Dictionary(uniqueKeysWithValues: snap.sessions.map { ($0.sessionId, $0.state) })
    #expect(byId[session.id.uuidString] == .unprotectedState)
    #expect(byId[ghost.uuidString] == .missing)
}

@Test
func setProtectedBatchRejectsUnknownIdWithoutMutatingAnything() async throws {
    // Validation is all-or-none and runs before any mutation: an
    // unknown id in the batch throws and flips nothing, so a partial
    // batch can never leave a torn protected/unprotected set for a tab.
    let manager = SessionManager()
    let alpha = try await manager.makeSessionState(label: nil)
    let beta = try await manager.makeSessionState(label: nil)
    await #expect(throws: SessionError.self) {
        try await manager.setProtectedBatch(
            sessionIds: [alpha.id, beta.id, UUID()],
            isProtected: true,
            revision: 1,
            epoch: 1
        )
    }
    #expect(await manager.isProtected(alpha.id) == false)
    #expect(await manager.isProtected(beta.id) == false)
}

private func spawnDeadChildAndReap() throws -> pid_t {
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [
        strdup("/usr/bin/true"),
        nil
    ]
    defer { argv.compactMap(\.self).forEach { free($0) } }
    let status = posix_spawn(&pid, "/usr/bin/true", nil, nil, argv, environ)
    guard status == 0 else {
        throw POSIXError(.init(rawValue: status) ?? .EINVAL)
    }
    var waitStatus: Int32 = 0
    waitpid(pid, &waitStatus, 0)
    return pid
}

// MARK: - Test helpers

/// Atomic counter for tests that need deterministic ordering across
/// `@Sendable` closures. NSLock-backed because we can't import
/// `Synchronization.Atomic` portably yet.
private final class ManagedAtomicInt: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0
    func incrementAndGet() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
