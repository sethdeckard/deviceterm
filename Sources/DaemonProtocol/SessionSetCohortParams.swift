// SPDX-License-Identifier: GPL-3.0-or-later
//
// SessionSetCohortParams: wire shape for `session.setCohort`.
//
// A cohort is the set of sessions that jointly control a device pane. The GUI
// knows a cohort is a tab; the daemon never learns that, and nothing here
// carries a tab id. It records verified session incarnations, an ordered
// membership, and one representative for attribution.
//
// No `(sessionId, cap)` handshake: `.validatedGUI`-scoped, so the caller's
// audit token is the authority. A UDS caller must never reach this method at
// all, because membership decides who may drive another session's pane.
//
// `revision` is the client half of the ordering key; the daemon pairs it with
// the monotonic XPC connection id it derives itself. A request applies only
// when its key strictly dominates the cohort's stored key, which is what makes
// a GUI restart replaying low revisions harmless.

public struct SessionSetCohortParams: Codable, Sendable, Equatable {
    /// The cohort this request addresses. Minted by the GUI, opaque to the
    /// daemon, and stable for the life of the tab it stands for.
    public let cohortId: String
    public let revision: Int
    /// Complete ordered membership, replacing rather than amending. Order is
    /// the GUI's nomination sequence; the daemon reattributes to the first
    /// surviving member when the representative is torn down before the GUI
    /// can renominate.
    public let members: [String]
    /// Nominated representative. Must appear in `members`; the daemon
    /// validates rather than trusting it.
    public let representative: String
    /// A prior cohort this one replaces. Naming it is what permits a member to
    /// move between cohorts: the retirement and the placement commit together.
    /// Cohorts not named here are untouched, so restoring one tab never
    /// retires another tab's cohort.
    public let replaces: String?
    /// Pane records to bind to this cohort, each with the admission it is
    /// expected to be at.
    public let bindings: [SessionCohortBinding]?

    public init(
        cohortId: String,
        revision: Int,
        members: [String],
        representative: String,
        replaces: String? = nil,
        bindings: [SessionCohortBinding]? = nil
    ) {
        self.cohortId = cohortId
        self.revision = revision
        self.members = members
        self.representative = representative
        self.replaces = replaces
        self.bindings = bindings
    }
}
