// SPDX-License-Identifier: GPL-3.0-or-later
//
// SessionCohortState: which sessions jointly control a device pane, as a value
// type `PaneCoordinator` owns outright.
//
// A session is the caller's authenticated identity. The product-level authority
// boundary is the tab, so every terminal in a tab reaches that tab's device
// panes. The daemon keeps no tab concept: what it stores is an opaque cohort id
// the GUI mints and retains, an ordered membership of verified session
// incarnations, and one representative for attribution.
//
// **Why a value type inside `PaneCoordinator` rather than its own actor.**
// Cohort membership and pane records are one consistency domain: a membership
// change decides who may drive a pane and rebinds pane records, and those have
// to happen together or not at all. Splitting them across two actors made every
// operation a distributed transaction, and the mirrors, fences, rollback
// generations, liveness callbacks and side-channel results that transaction
// needed grew larger than the state they coordinated. Here every method is
// synchronous, so the coordinator commits the whole change in one actor turn
// and there is no window to get wrong.
//
// Nothing here suspends, and nothing here reads the outside world. Session
// liveness arrives as a parameter, which is what keeps it that way.
//
// Membership is ordered. The order is the GUI's nomination sequence, carried
// on the wire so a representative reattribution after a member teardown is a
// rule both layers can state identically: the first surviving member in order.
//
// Membership governs *control only*. What happens to a closing session's
// devices — detach, shutdown, or handing them to a sibling — is untouched by
// this type: a session close takes exactly the path it took before cohorts.

import DaemonProtocol
import Foundation

/// One verified member of a cohort. The incarnation is what makes a restored
/// session with the same UUID a *different* member: without it, closing a
/// session and restoring it would silently re-open access granted to the
/// earlier one.
public struct CohortMember: Sendable, Equatable, Hashable {
    public let sessionId: UUID
    public let incarnation: UInt64

    public init(sessionId: UUID, incarnation: UInt64) {
        self.sessionId = sessionId
        self.incarnation = incarnation
    }
}

/// What a pane record's cohort reference resolves to for authorization.
///
/// The three cases are deliberately distinct, and collapsing the last two is
/// the bug this type exists to prevent: treating "this pane never had a cohort"
/// and "this pane's cohort is gone" identically would hand the pane back to
/// whichever single session attached it the moment a cohort was retired.
enum CohortResolution: Sendable, Equatable {
    /// The record names no cohort. Compatibility only. The caller falls back to
    /// the record's legacy owner.
    case unbound
    /// A live cohort. These are the sessions permitted to drive the pane. The
    /// member list can be empty — every member torn down, none reconciled back
    /// yet — and an empty list admits nobody.
    case live(members: [CohortMember], representative: UUID)
    /// The record names a cohort that is retired or was never installed. No
    /// session may drive it; the GUI keeps rendering it as `.guiPeer`.
    case denied
}

/// Why a reconcile did not commit.
enum CohortReconcileRejection: Sendable, Equatable {
    case staleKey
    case memberInForeignCohort
    case representativeNotAMember
    /// A replacement could not rebind every pane referencing the outgoing
    /// cohort, so the whole request was refused rather than stranding one.
    case bindingRefused
    /// The id was retired by a replacement. A retired id is dead for good:
    /// accepting a late reconcile for it would rebind panes away from the
    /// cohort that replaced it.
    case cohortRetired
    /// A named member is not live at the incarnation given.
    case memberNotLive
}

/// Everything one cohort reconcile decided, returned by value.
///
/// No caller reads a "last result" property. A transition's consequences
/// belong to that transition, and an actor-global side channel can be
/// overwritten by an intervening call before the caller gets to it.
struct CohortTransition: Sendable, Equatable {
    var applied: Bool = false
    var rejection: CohortReconcileRejection?
    var bindings: [SessionCohortBindingResult] = []
}

struct SessionCohortState: Sendable {
    private struct Cohort: Sendable, Equatable {
        var members: [CohortMember]
        var representative: UUID
        var key: ProtectionOrderingKey
    }

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
        if let replaces, isReplacement {
            retire(cohortId: replaces)
        }
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
        return CohortTransition(applied: true)
    }

    /// Drop a member torn down for any reason: an explicit close, or a
    /// restore-batch reap that removes it without one.
    ///
    /// Removes exactly the `(sessionId, incarnation)` named, so a delayed
    /// teardown of one incarnation can never evict the same UUID restored and
    /// reconciled at a newer one. The cohort record survives even when this
    /// empties it: see `tombstones`.
    mutating func tearDown(member: CohortMember) {
        guard let cohortId = byMember[member], var cohort = cohorts[cohortId] else { return }
        byMember[member] = nil
        cohort.members.removeAll { $0 == member }
        if cohort.representative == member.sessionId, let first = cohort.members.first {
            cohort.representative = first.sessionId
        }
        cohorts[cohortId] = cohort
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
        for member in members {
            if let owner = byMember[member], owner != cohortId, owner != replaces {
                return .memberInForeignCohort
            }
            guard isLive(member) else { return .memberNotLive }
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
}
