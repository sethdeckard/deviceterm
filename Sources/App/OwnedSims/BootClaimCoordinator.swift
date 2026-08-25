// SPDX-License-Identifier: GPL-3.0-or-later
//
// BootClaimCoordinator: the app-wide, in-memory owner of simulator boot
// attempts whose attribution must survive RPC timeout or daemon replacement.

import DaemonProtocol
import Foundation

@MainActor
final class BootClaimCoordinator {
    private enum ClaimPhase {
        case active
        case prepared
        case resolving
    }

    private struct PendingClaim {
        var evidence: BootClaimEvidence
        var sessionId: String?
        let deadlineNanoseconds: UInt64
        var phase: ClaimPhase
        let order: UInt64
    }

    private struct ClosedSession {
        let outcome: CohortCloseOutcome
        let expiresAtNanoseconds: UInt64
    }

    private struct ClaimTask {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let daemon: any DeviceControlling
    private let didPromote: @MainActor (String, String?, Int) -> Void
    private let clock: @Sendable () -> UInt64
    private let sleep: @Sendable (UInt64) async throws -> Void
    private var claims: [String: PendingClaim] = [:]
    private var tasks: [String: ClaimTask] = [:]
    private var closedSessions: [String: ClosedSession] = [:]
    private var paused = false
    private var nextOrder: UInt64 = 0

    var pendingCount: Int { claims.count }

    init(
        daemon: any DeviceControlling,
        didPromote: @escaping @MainActor (String, String?, Int) -> Void,
        clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        }
    ) {
        self.daemon = daemon
        self.didPromote = didPromote
        self.clock = clock
        self.sleep = sleep
    }

    /// Retain a shim claim after its terminal-local relay has acknowledged it.
    func accept(
        sessionId: String,
        claim: BootClaimEvidence,
        deadlineNanoseconds: UInt64? = nil
    ) {
        guard claim.source == .shim else { return }
        insert(
            claim: claim,
            sessionId: sessionId,
            deadlineNanoseconds: deadlineNanoseconds,
            phase: .active,
            supersedeExisting: true
        )
    }

    /// Register a GUI boot before sending `device.boot`, so an uncertain RPC
    /// result still has a claim to reconcile.
    func beginGUIBoot(udid: String, sessionId: String) -> BootClaimEvidence {
        let claim = BootClaimEvidence(
            attemptId: UUID().uuidString.lowercased(),
            udid: udid,
            source: .gui,
            observedState: .requested
        )
        insert(
            claim: claim,
            sessionId: sessionId,
            deadlineNanoseconds: nil,
            phase: .prepared,
            supersedeExisting: false
        )
        return claim
    }

    /// Start reconciliation after `device.boot` has either answered or become
    /// uncertain. The claim was retained before the call, but starting a
    /// separate reconciliation request earlier could race the boot intent.
    func bootRequestFinished(attemptId: String, outcome: BootClaimRequestOutcome) {
        guard var pending = claims[attemptId], pending.phase == .prepared else { return }
        switch outcome {
        case .accepted:
            _ = establish(attemptId: attemptId)

        case .rejected:
            removeAndResume(attemptId: attemptId, udid: pending.evidence.udid)

        case .uncertain:
            pending.phase = .resolving
            claims[attemptId] = pending
            parkOtherClaims(forUDID: pending.evidence.udid, except: attemptId)
            schedule(attemptId: attemptId)
        }
    }

    /// A new connection may name a replacement daemon. Hold all retries until
    /// the authoritative session inventory has been restored on it.
    func connectionReplaced() {
        paused = true
        for entry in tasks.values { entry.task.cancel() }
        tasks = [:]
    }

    func resumeAfterSessionRestore() {
        paused = false
        for udid in Set(claims.values.map(\.evidence.udid)) {
            resumeClaim(forUDID: udid)
        }
    }

    func shutdown() {
        paused = true
        for entry in tasks.values { entry.task.cancel() }
        tasks = [:]
        claims = [:]
        closedSessions = [:]
    }

    /// Preserve the user's close choice for a boot that has not promoted
    /// yet, when no daemon verdict stands in front of the close: the
    /// compatibility arm, and the fallback when `beginClose` was refused or
    /// went unanswered.
    func sessionClosed(_ sessionId: String, mode: PaneCloseMode) {
        sessionClosed(sessionId, outcome: mode == .shutdown ? .shutdown : .detach)
    }

    /// Preserve the daemon's authoritative close verdict for a boot that
    /// has not promoted yet. A promotion keeps the claim attached, re-homed
    /// on the successor; a terminal verdict strips the session and stamps
    /// the disposition. The same rewrite the daemon applies to its own
    /// claims, so both tombstone layers record one answer.
    func sessionClosed(_ sessionId: String, outcome: CohortCloseOutcome) {
        let now = clock()
        closedSessions = closedSessions.filter { $0.value.expiresAtNanoseconds > now }
        let closeDeadline = now.addingReportingOverflow(
            BootClaimEvidence.maximumLeaseMilliseconds * 1_000_000
        )
        closedSessions[sessionId] = ClosedSession(
            outcome: outcome,
            expiresAtNanoseconds: closeDeadline.overflow ? UInt64.max : closeDeadline.partialValue
        )
        let resolved = resolvedOutcome(from: sessionId, at: now)
        for attemptId in Array(claims.keys) where claims[attemptId]?.sessionId == sessionId {
            guard var pending = claims[attemptId] else { continue }
            if case let .promote(successor) = resolved {
                pending.sessionId = successor
                pending.evidence = evidence(from: pending, disposition: .attach)
            } else {
                pending.sessionId = nil
                pending.evidence = evidence(
                    from: pending,
                    disposition: resolved == .shutdown ? .shutdown : .detach
                )
            }
            claims[attemptId] = pending
            if pending.phase != .prepared {
                schedule(attemptId: attemptId)
            }
        }
    }

    /// Follow a closed session's verdict through any promotion chain: A
    /// handed to B, B later closed toward C, so a claim naming A must reach
    /// C. The same walk the daemon runs over its own tombstones:
    /// path-compresses what it walks, is cycle-protected, a successor with
    /// no tombstone of its own is still live and ends the walk, and a
    /// terminal link stops the chain.
    private func resolvedOutcome(from sessionId: String, at now: UInt64) -> CohortCloseOutcome {
        guard var current = closedSessions[sessionId]?.outcome else { return .detach }
        var visited: Set<String> = [sessionId]
        var walked: [String] = [sessionId]
        while case let .promote(successor) = current {
            guard let next = closedSessions[successor],
                next.expiresAtNanoseconds > now else { break }
            guard visited.insert(successor).inserted else { break }
            walked.append(successor)
            current = next.outcome
        }
        for id in walked {
            guard let existing = closedSessions[id] else { continue }
            closedSessions[id] = ClosedSession(
                outcome: current,
                expiresAtNanoseconds: existing.expiresAtNanoseconds
            )
        }
        return current
    }

    private func insert(
        claim: BootClaimEvidence,
        sessionId: String?,
        deadlineNanoseconds: UInt64?,
        phase: ClaimPhase,
        supersedeExisting: Bool
    ) {
        guard let attemptUUID = UUID(uuidString: claim.attemptId),
            let deviceUUID = UUID(uuidString: claim.udid),
            claim.remainingLeaseMilliseconds > 0 else { return }
        let normalizedAttemptId = attemptUUID.uuidString.lowercased()
        let normalizedUDID = deviceUUID.uuidString.lowercased()
        let normalizedClaim = BootClaimEvidence(
            attemptId: normalizedAttemptId,
            udid: normalizedUDID,
            source: claim.source,
            observedState: claim.observedState,
            disposition: claim.disposition,
            remainingLeaseMilliseconds: claim.remainingLeaseMilliseconds
        )
        let lease = min(
            claim.remainingLeaseMilliseconds,
            BootClaimEvidence.maximumLeaseMilliseconds
        )
        let now = clock()
        closedSessions = closedSessions.filter { $0.value.expiresAtNanoseconds > now }
        // A claim naming a closed session takes that session's recorded
        // verdict, followed through any chain of promotions. A promotion
        // keeps the claim attached to the successor; a terminal verdict
        // strips the session and stamps the disposition.
        var effectiveSessionId = sessionId
        var terminalOutcome: CohortCloseOutcome?
        if let sessionId, closedSessions[sessionId] != nil {
            let resolved = resolvedOutcome(from: sessionId, at: now)
            if case let .promote(successor) = resolved {
                effectiveSessionId = successor
            } else {
                effectiveSessionId = nil
                terminalOutcome = resolved
            }
        }
        let effectiveClaim: BootClaimEvidence
        if let terminalOutcome {
            effectiveClaim = BootClaimEvidence(
                attemptId: normalizedAttemptId,
                udid: normalizedUDID,
                source: normalizedClaim.source,
                observedState: normalizedClaim.observedState,
                disposition: terminalOutcome == .shutdown ? .shutdown : .detach,
                remainingLeaseMilliseconds: claim.remainingLeaseMilliseconds
            )
        } else {
            effectiveClaim = normalizedClaim
        }
        let deadline = now.addingReportingOverflow(lease * 1_000_000)
        guard !deadline.overflow else { return }
        let fixedDeadline: UInt64
        if let deadlineNanoseconds {
            guard deadlineNanoseconds > now else { return }
            fixedDeadline = min(deadline.partialValue, deadlineNanoseconds)
        } else {
            fixedDeadline = deadline.partialValue
        }
        if var existing = claims[normalizedAttemptId] {
            existing.sessionId = effectiveSessionId
            existing.evidence = effectiveClaim
            claims[normalizedAttemptId] = existing
        } else {
            let order = nextOrder
            nextOrder &+= 1
            claims[normalizedAttemptId] = PendingClaim(
                evidence: effectiveClaim,
                sessionId: effectiveSessionId,
                deadlineNanoseconds: fixedDeadline,
                phase: phase,
                order: order
            )
        }
        if supersedeExisting {
            _ = establish(attemptId: normalizedAttemptId)
        }
    }

    /// Promote a prepared or resolving claim to the app's authoritative claim
    /// for its UDID. A later active attempt wins even if an older request
    /// resumes afterward; unresolved attempts only park the incumbent.
    @discardableResult
    private func establish(attemptId: String) -> Bool {
        guard var pending = claims[attemptId] else { return false }
        let udid = pending.evidence.udid
        let hasLaterActive = claims.contains { otherId, other in
            otherId != attemptId
                && other.evidence.udid == udid
                && other.order > pending.order
                && other.phase == .active
        }
        if hasLaterActive {
            claims.removeValue(forKey: attemptId)
            tasks.removeValue(forKey: attemptId)?.task.cancel()
            return false
        }
        let displaced = claims.compactMap { otherId, other in
            otherId != attemptId
                && other.evidence.udid == udid
                && other.order < pending.order
                ? otherId
                : nil
        }
        for otherId in displaced {
            claims.removeValue(forKey: otherId)
            tasks.removeValue(forKey: otherId)?.task.cancel()
        }
        pending.phase = .active
        claims[attemptId] = pending
        resumeClaim(forUDID: udid)
        return true
    }

    private func parkOtherClaims(forUDID udid: String, except attemptId: String) {
        for (otherId, other) in claims where otherId != attemptId
            && other.evidence.udid == udid
            && other.phase != .prepared {
            tasks.removeValue(forKey: otherId)?.task.cancel()
        }
    }

    private func removeAndResume(attemptId: String, udid: String) {
        claims.removeValue(forKey: attemptId)
        tasks.removeValue(forKey: attemptId)?.task.cancel()
        resumeClaim(forUDID: udid)
    }

    /// At most one claim per UDID may reconcile. An uncertain candidate parks
    /// the prior accepted claim until the candidate is established or rejected.
    private func resumeClaim(forUDID udid: String) {
        guard !paused else { return }
        let sameDevice = claims.filter { $0.value.evidence.udid == udid }
        if let resolving = sameDevice
            .filter({ $0.value.phase == .resolving })
            .max(by: { $0.value.order < $1.value.order }) {
            parkOtherClaims(forUDID: udid, except: resolving.key)
            schedule(attemptId: resolving.key)
            return
        }
        if let active = sameDevice
            .filter({ $0.value.phase == .active })
            .max(by: { $0.value.order < $1.value.order }) {
            schedule(attemptId: active.key)
        }
    }

    private func schedule(attemptId: String) {
        guard !paused, tasks[attemptId] == nil,
            let scheduled = claims[attemptId], scheduled.phase != .prepared else { return }
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var backoff: UInt64 = 100_000_000
            defer { self.finishTask(attemptId: attemptId, token: token) }
            while !Task.isCancelled, !self.paused {
                guard let pending = self.claims[attemptId] else { return }
                let now = self.clock()
                guard now < pending.deadlineNanoseconds else {
                    self.removeAndResume(
                        attemptId: attemptId,
                        udid: pending.evidence.udid
                    )
                    return
                }
                do {
                    let answer = try await self.daemon.reconcileBootClaim(
                        claim: self.evidence(from: pending),
                        sessionId: pending.sessionId
                    )
                    guard !Task.isCancelled,
                        self.tasks[attemptId]?.token == token,
                        let current = self.claims[attemptId] else { return }
                    guard answer.result.attemptId == attemptId,
                        answer.result.udid.caseInsensitiveCompare(pending.evidence.udid)
                            == .orderedSame else { return }
                    switch answer.result.status {
                    case .pending:
                        // Pending includes daemon candidates registered before
                        // CoreSimulator accepts the boot. It is not evidence
                        // that a resolving claim may displace its incumbent.
                        break

                    case .promoted:
                        guard self.establish(attemptId: attemptId) else { return }
                        self.claims.removeValue(forKey: attemptId)
                        if current.evidence.disposition != .shutdown {
                            self.didPromote(
                                answer.result.udid,
                                answer.result.sessionId,
                                answer.generation
                            )
                        }
                        return

                    case .canceled, .expired, .failed, .superseded:
                        self.removeAndResume(
                            attemptId: attemptId,
                            udid: current.evidence.udid
                        )
                        return
                    }
                } catch {
                    // An unanswered request has an unknown outcome. Keep the
                    // causal claim until a later answer or its fixed lease.
                }
                do {
                    try await self.sleep(backoff)
                } catch {
                    return
                }
                backoff = min(backoff * 2, 2_000_000_000)
            }
        }
        tasks[attemptId] = ClaimTask(token: token, task: task)
    }

    private func finishTask(attemptId: String, token: UUID) {
        guard tasks[attemptId]?.token == token else { return }
        tasks[attemptId] = nil
    }

    private func evidence(
        from pending: PendingClaim,
        disposition: BootClaimDisposition? = nil
    ) -> BootClaimEvidence {
        let now = clock()
        let remaining = pending.deadlineNanoseconds > now
            ? (pending.deadlineNanoseconds - now) / 1_000_000
            : 0
        return BootClaimEvidence(
            attemptId: pending.evidence.attemptId,
            udid: pending.evidence.udid,
            source: pending.evidence.source,
            observedState: pending.evidence.observedState,
            disposition: disposition ?? pending.evidence.disposition,
            remainingLeaseMilliseconds: remaining
        )
    }
}
