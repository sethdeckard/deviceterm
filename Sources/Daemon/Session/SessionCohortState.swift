// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Which sessions jointly control a device pane, as a value
/// type `PaneCoordinator` owns outright.
///
/// A session is the caller's authenticated identity. The product-level authority
/// boundary is the tab, so every terminal in a tab reaches that tab's device
/// panes. The daemon keeps no tab concept: what it stores is an opaque cohort id
/// the GUI mints and retains, an ordered membership of verified session
/// incarnations, and one representative for attribution.
///
/// **Why a value type inside `PaneCoordinator` rather than its own actor.**
/// Cohort membership and pane records form one consistency domain: a membership
/// change decides who may drive a pane and rebinds pane records, and those must
/// commit together in one actor turn. Every method here is synchronous, so
/// there is no window between deciding and committing for anything to slip
/// into.
///
/// Nothing here suspends, and nothing here reads the outside world. Session
/// liveness arrives as a parameter, which is what keeps it that way.
///
/// Membership is ordered. The order is the GUI's nomination sequence, carried
/// on the wire so who inherits from a closing member is a rule both layers can
/// state identically: the first surviving member in order.
///
/// A close verdict is decided exactly once per member, at the first of three
/// entry points to reach it (`beginClose`, an explicit close's
/// `recordCloseVerdict`, or a reap's `tearDown`), and the record of it is what
/// makes the other two no-ops. The verdict and its device consequence commit
/// in the same actor turn, so a later close path cannot lose a promotion by
/// re-deciding against membership the close already removed.
struct SessionCohortState: Sendable {
    private struct Cohort: Sendable, Equatable {
        var members: [CohortMember]
        var representative: UUID
        var key: ProtectionOrderingKey
    }

    private struct VerdictRecord: Sendable {
        let outcome: CohortCloseOutcome
        let recordedAt: UInt64
    }

    /// A journalled `beginClose`, carrying the request identity alongside the
    /// outcome: a replay answers only the request that earned it. Without the
    /// comparison, a transition id reused for a *different* close would
    /// report an unrelated verdict as applied.
    private struct JournalEntry: Sendable {
        let outcome: CohortCloseOutcome
        let cohortId: UUID
        let leaving: Set<UUID>
        let mode: PaneCloseMode
        let recordedAt: UInt64
    }

    /// How long a recorded verdict or journal entry survives. Matched to
    /// `BootClaimEvidence.maximumLeaseMilliseconds`: nothing that would
    /// consume one outlives the boot-claim lease.
    static let retentionNanoseconds: UInt64 =
        BootClaimEvidence.maximumLeaseMilliseconds * 1_000_000

    private var cohorts: [UUID: Cohort] = [:]
    /// Ids retired by a replacement. Dead for good: without this, nothing
    /// remembers the retired id's ordering key, so a delayed reconcile naming
    /// it would face no staleness check at all and could quietly rebuild the
    /// cohort its replacement retired.
    ///
    /// A cohort merely *emptied* by member teardown is not in here: it keeps
    /// its record and key, admits nobody, and a same-id reconcile under a
    /// dominating key revives it. The GUI retains one cohort id per tab across
    /// restores, so an emptied id must stay reusable.
    private var tombstones: Set<UUID> = []
    /// Exactly one cohort per live session incarnation. Without this a
    /// reconnect could leave a session in an old cohort while adding it to a
    /// new one, giving it authority through two.
    private var byMember: [CohortMember: UUID] = [:]
    /// One close verdict per exact member, recorded by whichever close path
    /// reached it first. Its existence is what makes the other paths no-ops,
    /// and its incarnation key is what stops a restored session consuming a
    /// predecessor's verdict.
    private var verdicts: [CohortMember: VerdictRecord] = [:]
    /// `beginClose` outcomes by transition id, so a retry after a lost reply
    /// returns the same answer instead of deciding (and promoting) again.
    private var journal: [UUID: JournalEntry] = [:]

    // MARK: - Reads

    /// Resolve a pane record's cohort reference to the sessions permitted to
    /// drive it.
    func resolve(cohortId: UUID?) -> CohortResolution {
        guard let cohortId else { return .unbound }
        guard let cohort = cohorts[cohortId] else { return .denied }
        return .live(members: cohort.members, representative: cohort.representative)
    }

    func cohortId(forMember member: CohortMember) -> UUID? {
        byMember[member]
    }

    func members(ofCohort cohortId: UUID) -> [CohortMember] {
        cohorts[cohortId]?.members ?? []
    }

    // MARK: - Transitions

    /// Install or replace a cohort's complete membership.
    ///
    /// All-or-none, and entirely synchronous: the caller has already gathered
    /// liveness and binding feasibility, so there is no suspension between the
    /// checks and the commit for a competing transition to slip into.
    ///
    /// `bindingsSucceed` reports whether every pane the caller must rebind can
    /// be rebound. A replacement that cannot rebind them all is refused
    /// outright, because a pane left naming a retired cohort resolves `.denied`
    /// and refuses every session: safe, but a live pane nobody can drive.
    mutating func reconcile(
        cohortId: UUID,
        members: [CohortMember],
        representative: UUID,
        replaces: UUID?,
        key: ProtectionOrderingKey,
        isLive: (CohortMember) -> Bool,
        bindingsSucceed: Bool
    ) -> CohortTransition {
        if let rejection = validate(
            cohortId: cohortId,
            members: members,
            representative: representative,
            replaces: replaces,
            key: key,
            isLive: isLive
        ) {
            return CohortTransition(applied: false, rejection: rejection)
        }
        let isReplacement = replaces != nil && replaces != cohortId
        if isReplacement, !bindingsSucceed {
            return CohortTransition(applied: false, rejection: .bindingRefused)
        }
        var transition = CohortTransition(applied: true)
        var previous = cohorts[cohortId]?.members ?? []
        if let replaces, isReplacement {
            previous += cohorts[replaces]?.members ?? []
            retire(cohortId: replaces)
        }
        transition.removed = previous.filter { !members.contains($0) }
        for (member, owner) in byMember where owner == cohortId {
            byMember[member] = nil
        }
        for member in members {
            byMember[member] = cohortId
        }
        cohorts[cohortId] = Cohort(
            members: members,
            representative: representative,
            key: key
        )
        return transition
    }

    /// Commit a close verdict for some of a cohort's members, ahead of their
    /// actual closes.
    ///
    /// Idempotent under `transitionId` while its journal entry is retained
    /// (the boot-claim lease): the verdict is journalled in the same turn it
    /// is decided, so a retry arriving after the cohort has lost those
    /// members replays the same answer with nothing left to remove. The
    /// caller re-homes and emits only for `closed`, which a replay leaves
    /// empty.
    mutating func beginClose(
        cohortId: UUID,
        transitionId: UUID,
        leaving: [UUID],
        mode: PaneCloseMode,
        key: ProtectionOrderingKey,
        now: UInt64
    ) -> CohortCloseCommit {
        prune(now: now)
        let leavingIds = Set(leaving)
        if let journalled = journal[transitionId] {
            // A replay answers only the request that earned it: a transition
            // id reused with a different cohort, member set, or mode is a
            // caller bug, and reporting the old verdict as applied for it
            // would record the wrong answer in the GUI's tombstone.
            guard journalled.cohortId == cohortId, journalled.leaving == leavingIds,
                journalled.mode == mode else {
                return CohortCloseCommit(applied: false)
            }
            return CohortCloseCommit(applied: true, outcome: journalled.outcome)
        }
        guard var cohort = cohorts[cohortId] else {
            // Unknown or retired. The GUI still needs an authoritative answer
            // to proceed with the close, and there are no members left to
            // decide for, so the requested mode is journalled as-is. Nothing
            // is recorded per member: without the cohort there are no
            // incarnations to key by, and an unkeyed verdict would be
            // consumable by a restored session.
            //
            // But only when none of the named ids belongs to any live cohort.
            // After a replacement, a delayed close naming the retired id
            // could otherwise return a terminal verdict for a session now in
            // the replacement cohort, whose real close derives a promotion
            // there, leaving the two tombstone layers recording different
            // answers.
            // Refused without consuming the transition id, so a corrected
            // retry can still repair it.
            guard !byMember.keys.contains(where: { leavingIds.contains($0.sessionId) }) else {
                return CohortCloseCommit(applied: false)
            }
            let outcome = terminalOutcome(for: mode)
            journal[transitionId] = JournalEntry(
                outcome: outcome,
                cohortId: cohortId,
                leaving: leavingIds,
                mode: mode,
                recordedAt: now
            )
            return CohortCloseCommit(applied: true, outcome: outcome)
        }
        let leavingMembers = cohort.members.filter { leavingIds.contains($0.sessionId) }
        // All-or-none over the NAMED ids: every one must be a current member.
        // A partial match would return one verdict as the authoritative
        // answer for sessions this commit never decided, whose later closes
        // can land anywhere; two tombstone layers recording different
        // answers is exactly what this operation exists to prevent. And a
        // wholly foreign set must not burn the transition id, so a corrected
        // retry can still repair it.
        guard !leavingMembers.isEmpty,
            Set(leavingMembers.map(\.sessionId)) == leavingIds else {
            return CohortCloseCommit(applied: false)
        }
        guard key > cohort.key else { return CohortCloseCommit(applied: false) }
        cohort.key = key
        let survivors = cohort.members.filter { !leavingIds.contains($0.sessionId) }
        let outcome: CohortCloseOutcome
        var successor: CohortMember?
        if let first = survivors.first {
            outcome = .promote(successor: first.sessionId.uuidString)
            successor = first
            if leavingIds.contains(cohort.representative) {
                cohort.representative = first.sessionId
            }
        } else {
            outcome = terminalOutcome(for: mode)
        }
        cohort.members = survivors
        cohorts[cohortId] = cohort
        for member in leavingMembers {
            byMember[member] = nil
            verdicts[member] = VerdictRecord(outcome: outcome, recordedAt: now)
        }
        journal[transitionId] = JournalEntry(
            outcome: outcome,
            cohortId: cohortId,
            leaving: leavingIds,
            mode: mode,
            recordedAt: now
        )
        return CohortCloseCommit(
            applied: true,
            outcome: outcome,
            closed: leavingMembers,
            successor: successor
        )
    }

    /// Decide a close verdict for one member whose close is in flight, when no
    /// `beginClose` preceded it: a session closing itself over UDS.
    ///
    /// Derived here, never taken from the caller, because a client that could
    /// name its own successor could hand itself another session's simulator. A
    /// member of no cohort takes the requested terminal mode.
    mutating func recordCloseVerdict(
        member: CohortMember,
        mode: PaneCloseMode,
        now: UInt64
    ) -> CohortCloseDecision {
        prune(now: now)
        if verdicts[member] != nil { return .alreadyRecorded }
        guard let cohortId = byMember[member], var cohort = cohorts[cohortId] else {
            let outcome = terminalOutcome(for: mode)
            verdicts[member] = VerdictRecord(outcome: outcome, recordedAt: now)
            return .decided(outcome: outcome, successor: nil)
        }
        byMember[member] = nil
        cohort.members.removeAll { $0 == member }
        let outcome: CohortCloseOutcome
        var successor: CohortMember?
        if let first = cohort.members.first {
            outcome = .promote(successor: first.sessionId.uuidString)
            successor = first
            if cohort.representative == member.sessionId {
                cohort.representative = first.sessionId
            }
        } else {
            outcome = terminalOutcome(for: mode)
        }
        cohorts[cohortId] = cohort
        verdicts[member] = VerdictRecord(outcome: outcome, recordedAt: now)
        return .decided(outcome: outcome, successor: successor)
    }

    /// Drop a member torn down for any reason: an explicit close, or a
    /// restore-batch reap that removes it without one.
    ///
    /// Removes exactly the `(sessionId, incarnation)` named, so a delayed
    /// teardown of one incarnation can never evict the same UUID restored and
    /// reconciled at a newer one. The cohort record survives even when this
    /// empties it: see `tombstones`.
    mutating func tearDown(member: CohortMember, now: UInt64) -> CohortTearDownDisposition {
        prune(now: now)
        if verdicts[member] != nil {
            // The close paths remove membership when they record, so this is
            // ordinarily a no-op sweep; removing again is harmless.
            removeMembership(member)
            return .alreadyDecided
        }
        guard let cohortId = byMember[member], var cohort = cohorts[cohortId] else {
            return .terminal
        }
        byMember[member] = nil
        cohort.members.removeAll { $0 == member }
        guard let first = cohort.members.first else {
            cohorts[cohortId] = cohort
            return .terminal
        }
        if cohort.representative == member.sessionId {
            cohort.representative = first.sessionId
        }
        cohorts[cohortId] = cohort
        verdicts[member] = VerdictRecord(
            outcome: .promote(successor: first.sessionId.uuidString),
            recordedAt: now
        )
        return .promoted(successor: first)
    }

    // MARK: - Private

    /// The reconcile preconditions. Synchronous by construction: liveness
    /// arrives as a closure the caller has already resolved, so nothing here
    /// suspends between the checks and the commit that follows them.
    private func validate(
        cohortId: UUID,
        members: [CohortMember],
        representative: UUID,
        replaces: UUID?,
        key: ProtectionOrderingKey,
        isLive: (CohortMember) -> Bool
    ) -> CohortReconcileRejection? {
        if tombstones.contains(cohortId) { return .cohortRetired }
        if let existing = cohorts[cohortId] {
            guard key > existing.key else { return .staleKey }
        }
        // Retiring the outgoing cohort is a mutation of *that* cohort, so it
        // has to dominate that key too. Comparing only against the incoming id
        // would let a fresh-id request retire newer outgoing state.
        if let replaces, replaces != cohortId {
            if tombstones.contains(replaces) { return .cohortRetired }
            if let outgoing = cohorts[replaces] {
                guard key > outgoing.key else { return .staleKey }
            }
        }
        guard members.contains(where: { $0.sessionId == representative }) else {
            return .representativeNotAMember
        }
        guard Set(members).count == members.count else { return .duplicateMember }
        for member in members {
            if let owner = byMember[member], owner != cohortId, owner != replaces {
                return .memberInForeignCohort
            }
            guard isLive(member) else { return .memberNotLive }
            // A close already decided this exact member. Between `beginClose`
            // and the session's actual removal it is still live and its
            // active incarnation still resolves, so liveness alone would let
            // a dominating reconcile install it right back.
            guard verdicts[member] == nil else { return .memberClosed }
        }
        return nil
    }

    private mutating func retire(cohortId: UUID) {
        for (member, owner) in byMember where owner == cohortId {
            byMember[member] = nil
        }
        cohorts[cohortId] = nil
        tombstones.insert(cohortId)
    }

    private func terminalOutcome(for mode: PaneCloseMode) -> CohortCloseOutcome {
        mode == .shutdown ? .shutdown : .detach
    }

    private mutating func removeMembership(_ member: CohortMember) {
        guard let cohortId = byMember[member], var cohort = cohorts[cohortId] else { return }
        byMember[member] = nil
        cohort.members.removeAll { $0 == member }
        if cohort.representative == member.sessionId, let first = cohort.members.first {
            cohort.representative = first.sessionId
        }
        cohorts[cohortId] = cohort
    }

    /// Drop verdicts and journal entries past retention. The device layer's
    /// own tombstones carry the late-claim behaviour on their own lease, so
    /// nothing here needs to outlive one.
    private mutating func prune(now: UInt64) {
        verdicts = verdicts.filter { now &- $0.value.recordedAt < Self.retentionNanoseconds }
        journal = journal.filter { now &- $0.value.recordedAt < Self.retentionNanoseconds }
    }
}
