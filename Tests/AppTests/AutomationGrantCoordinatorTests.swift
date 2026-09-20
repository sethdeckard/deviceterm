// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import Testing

@MainActor
private func makeCoordinator(_ fake: FakeDaemonClient) -> AutomationGrantCoordinator {
    // No-delay sleep so retries run without real time.
    AutomationGrantCoordinator(client: fake, sleep: { _ in true })
}

/// A controllable backoff: each `sleep` parks until the test releases it, so a
/// test can catch a retry loop mid-backoff (after it has thrown once) and cancel
/// it there: the exact in-flight state `sessionRemoved` / `cancelAll` must
/// handle.
@MainActor
private final class SleepGate {
    private var continuations: [CheckedContinuation<Bool, Never>] = []

    var parkedCount: Int { continuations.count }

    func sleep(_ nanos: UInt64) async -> Bool {
        await withCheckedContinuation { continuations.append($0) }
    }

    func releaseAll(_ value: Bool) {
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume(returning: value) }
    }
}

/// Yield until `condition` holds or a bound elapses (retry loops resume across
/// `await` points, so a bounded yield-poll settles them deterministically).
@MainActor
private func yieldUntil(_ condition: () -> Bool) async {
    for _ in 0..<2_000 where !condition() { await Task.yield() }
}

/// Poll until the coordinator has no in-flight retry loop (bounded), so the
/// detached grant task has settled before asserting.
@MainActor
private func drain(_ coord: AutomationGrantCoordinator) async {
    for _ in 0..<2_000 where !coord.pendingSessionsForTesting.isEmpty {
        await Task.yield()
    }
}

/// The GUI half of the automation-grant lifecycle: once an automation tab's
/// terminal is bound, the coordinator issues its grant and KEEPS it: retrying
/// transient failures (a connection blip, a `notReady` validation flake) with
/// fresh revisions until it applies, so a validation outage lasting beyond the
/// bind loop still recovers without waiting for an unrelated reconnect. An agent
/// tab is never granted. Reconnect rebind reissues under the fresh epoch.
///
/// Paired with the daemon half (`AutomationGrantUDSScopeTests`, a granted UDS
/// session reaches `pane.sendInput`/`pane.captureText`), this is the end-to-end
/// "open automation tab → grant issued → CLI reaches the verbs" chain, split
/// at the process boundary a unit test can't cross.
@MainActor
struct AutomationGrantCoordinatorTests {
    @Test
    func automationTabIssuesGrantForBoundSession() async {
        let fake = FakeDaemonClient()
        let coord = makeCoordinator(fake)
        let sid = UUID()
        coord.sessionBound(role: .automation, sessionId: sid.uuidString)
        await drain(coord)
        #expect(fake.grantAutomationCalls.count == 1)
        #expect(fake.grantAutomationCalls.first?.sessionIds == [sid])
    }

    @Test
    func agentTabIssuesNoGrant() async {
        let fake = FakeDaemonClient()
        let coord = makeCoordinator(fake)
        coord.sessionBound(role: .agent, sessionId: UUID().uuidString)
        await drain(coord)
        #expect(fake.grantAutomationCalls.isEmpty)
    }

    @Test
    func malformedSessionIdIssuesNoGrant() async {
        let fake = FakeDaemonClient()
        let coord = makeCoordinator(fake)
        coord.sessionBound(role: .automation, sessionId: "not-a-uuid")
        await drain(coord)
        #expect(fake.grantAutomationCalls.isEmpty)
    }

    @Test
    func transientFailureRetriesWithFreshRevisionsUntilApplied() async {
        // Two transient failures then success → three attempts, each a fresh
        // (strictly increasing) revision, converging on a grant. This is the
        // outage-recovery the one-shot issuer lacked.
        let fake = FakeDaemonClient()
        fake.grantAutomationFailures = [
            DaemonClientError.transport("blip"),
            DaemonClientError.daemon(code: -32_002, message: "notReady")
        ]
        let coord = makeCoordinator(fake)
        coord.sessionBound(role: .automation, sessionId: UUID().uuidString)
        await drain(coord)
        #expect(fake.grantAutomationCalls.count == 3)
        let revisions = fake.grantAutomationCalls.map(\.revision)
        #expect(revisions == revisions.sorted() && Set(revisions).count == 3)
    }

    @Test
    func timedOutGrantRetriesLikeATransportDrop() async {
        // The bound expired before the helper answered. That is silence, not a
        // verdict, so the grant is reissued once the helper catches up.
        let fake = FakeDaemonClient()
        fake.grantAutomationFailures = [
            DaemonClientError.timedOut(method: "automation.grant")
        ]
        let coord = makeCoordinator(fake)
        coord.sessionBound(role: .automation, sessionId: UUID().uuidString)
        await drain(coord)
        #expect(fake.grantAutomationCalls.count == 2)
    }

    @Test
    func terminalErrorStopsRetrying() async {
        // A dead session (`invalidParams`) or a stable scope_violation is
        // terminal. Retrying can't help, so it fails closed after one attempt.
        let fake = FakeDaemonClient()
        fake.grantAutomationFailures = [
            DaemonClientError.daemon(code: -32_602, message: "not a live session"),
            // A second scripted failure that must NEVER be reached (no retry).
            DaemonClientError.transport("should-not-retry")
        ]
        let coord = makeCoordinator(fake)
        coord.sessionBound(role: .automation, sessionId: UUID().uuidString)
        await drain(coord)
        #expect(fake.grantAutomationCalls.count == 1)
    }

    @Test
    func appliedFalseStopsRetrying() async {
        // `applied: false` means a newer connection epoch already owns the
        // grant. Stop, don't fight it.
        let fake = FakeDaemonClient()
        fake.grantAutomationApplied = [false]
        let coord = makeCoordinator(fake)
        coord.sessionBound(role: .automation, sessionId: UUID().uuidString)
        await drain(coord)
        #expect(fake.grantAutomationCalls.count == 1)
    }

    /// The applied grant is the only moment a session is known to hold
    /// automation authority. A configured automation program's command waits
    /// on this rather than running at terminal attach, where it would race
    /// the bind-and-grant sequence.
    @Test
    func anAppliedGrantAnnouncesItsSession() async {
        let fake = FakeDaemonClient()
        let coord = makeCoordinator(fake)
        var granted: [UUID] = []
        coord.onGranted = { granted.append($0) }
        let sid = UUID()
        coord.sessionBound(role: .automation, sessionId: sid.uuidString)
        await drain(coord)
        #expect(granted == [sid])
    }

    @Test
    func aSupersededGrantAnnouncesNothing() async {
        let fake = FakeDaemonClient()
        fake.grantAutomationApplied = [false]
        let coord = makeCoordinator(fake)
        var granted: [UUID] = []
        coord.onGranted = { granted.append($0) }
        coord.sessionBound(role: .automation, sessionId: UUID().uuidString)
        await drain(coord)
        #expect(granted.isEmpty)
    }

    /// An agent tab is never granted, so nothing waiting on a grant can be
    /// released by one.
    @Test
    func anAgentSessionAnnouncesNothing() async {
        let fake = FakeDaemonClient()
        let coord = makeCoordinator(fake)
        var granted: [UUID] = []
        coord.onGranted = { granted.append($0) }
        coord.sessionBound(role: .agent, sessionId: UUID().uuidString)
        await drain(coord)
        #expect(granted.isEmpty)
    }

    /// The retry loop's guard runs before the grant request is awaited, so a
    /// reconnect landing while the reply is in flight leaves the old frame
    /// holding a result it must not act on: the grant it describes belongs to
    /// the old connection, whose teardown revokes it. Announcing it would
    /// report authority that is already going away, and a consumer latching
    /// on a once-only action would spend that latch before the replacement
    /// grant lands.
    @Test
    func aSupersededFrameAnnouncesNothingWhenItsReplyArrives() async {
        let fake = FakeDaemonClient()
        let coord = makeCoordinator(fake)
        var granted: [UUID] = []
        coord.onGranted = { granted.append($0) }
        let sid = UUID()

        // Park the first grant mid-flight, then land a reconnect rebind.
        fake.armGrantAutomationBarrier()
        coord.sessionBound(role: .automation, sessionId: sid.uuidString)
        await yieldUntil { fake.grantAutomationCalls.count == 1 }
        coord.sessionBound(role: .automation, sessionId: sid.uuidString)

        // Release both: the superseded frame's reply must be discarded, and
        // only the replacement's may announce.
        fake.releaseGrantAutomationBarrier()
        await drain(coord)
        #expect(fake.grantAutomationCalls.count == 2)
        #expect(granted == [sid])
    }

    @Test
    func reconnectRebindReissuesWithDominatingRevision() async {
        // sessionBound fires on the initial bind AND every reconnect rebind, so
        // a second call models a reconnect. It supersedes cleanly and reissues
        // with a fresh, dominating revision.
        let fake = FakeDaemonClient()
        let coord = makeCoordinator(fake)
        let sid = UUID()
        coord.sessionBound(role: .automation, sessionId: sid.uuidString)
        await drain(coord)
        coord.sessionBound(role: .automation, sessionId: sid.uuidString)
        await drain(coord)
        #expect(fake.grantAutomationCalls.count == 2)
        let revisions = fake.grantAutomationCalls.map(\.revision)
        #expect(revisions[1] > revisions[0])
    }

    @Test
    func sessionRemovedCancelsParkedRetryBeforeItRegrants() async {
        // A retry loop parked in backoff after a transient failure must NOT
        // fire another grant once its session is removed. Otherwise a lost
        // `session.close` could let it briefly regrant the still-live daemon
        // ghost. The one attempt already made stands; nothing after removal.
        let gate = SleepGate()
        let fake = FakeDaemonClient()
        fake.grantAutomationFailures = [DaemonClientError.transport("blip")]
        let coord = AutomationGrantCoordinator(client: fake, sleep: { await gate.sleep($0) })
        let sid = UUID()
        coord.sessionBound(role: .automation, sessionId: sid.uuidString)
        await yieldUntil { gate.parkedCount == 1 }
        #expect(fake.grantAutomationCalls.count == 1)  // threw once, now parked

        coord.sessionRemoved(sessionId: sid.uuidString)
        #expect(coord.pendingSessionsForTesting.isEmpty)  // dropped synchronously
        gate.releaseAll(true)  // wake the backoff: the loop must bail, not retry
        for _ in 0..<200 { await Task.yield() }
        #expect(fake.grantAutomationCalls.count == 1)  // no regrant after removal
    }

    @Test
    func cancelAllCancelsEveryParkedRetry() async {
        let gate = SleepGate()
        let fake = FakeDaemonClient()
        fake.grantAutomationFailures = [
            DaemonClientError.transport("a"),
            DaemonClientError.transport("b")
        ]
        let coord = AutomationGrantCoordinator(client: fake, sleep: { await gate.sleep($0) })
        coord.sessionBound(role: .automation, sessionId: UUID().uuidString)
        coord.sessionBound(role: .automation, sessionId: UUID().uuidString)
        await yieldUntil { gate.parkedCount == 2 }
        #expect(fake.grantAutomationCalls.count == 2)  // both threw once, parked

        coord.cancelAll()
        #expect(coord.pendingSessionsForTesting.isEmpty)
        gate.releaseAll(true)
        for _ in 0..<200 { await Task.yield() }
        #expect(fake.grantAutomationCalls.count == 2)  // neither retried after cancelAll
    }

    @Test
    func sessionRemovedForUntrackedSessionIsNoOp() {
        let fake = FakeDaemonClient()
        let coord = makeCoordinator(fake)
        coord.sessionRemoved(sessionId: UUID().uuidString)  // never tracked
        coord.sessionRemoved(sessionId: "not-a-uuid")
        #expect(coord.pendingSessionsForTesting.isEmpty)
        #expect(coord.generationEntryCountForTesting == 0)  // stored nothing
        #expect(fake.grantAutomationCalls.isEmpty)
    }

    @Test
    func completedGrantLeavesNoGenerationTombstone() async {
        let fake = FakeDaemonClient()
        let coord = makeCoordinator(fake)
        coord.sessionBound(role: .automation, sessionId: UUID().uuidString)
        await drain(coord)
        #expect(coord.pendingSessionsForTesting.isEmpty)
        #expect(coord.generationEntryCountForTesting == 0)  // cleared on completion
    }

    @Test
    func removalClearsGenerationTombstone() async {
        // A parked-then-removed loop must leave no generation entry behind.
        let gate = SleepGate()
        let fake = FakeDaemonClient()
        fake.grantAutomationFailures = [DaemonClientError.transport("blip")]
        let coord = AutomationGrantCoordinator(client: fake, sleep: { await gate.sleep($0) })
        let sid = UUID()
        coord.sessionBound(role: .automation, sessionId: sid.uuidString)
        await yieldUntil { gate.parkedCount == 1 }
        #expect(coord.generationEntryCountForTesting == 1)  // one live loop

        coord.sessionRemoved(sessionId: sid.uuidString)
        gate.releaseAll(true)
        for _ in 0..<200 { await Task.yield() }
        #expect(coord.pendingSessionsForTesting.isEmpty)
        #expect(coord.generationEntryCountForTesting == 0)  // no tombstone
    }
}
