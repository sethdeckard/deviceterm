// SPDX-License-Identifier: GPL-3.0-or-later
//
// SessionSetCohortParams: wire shape for `session.setCohort`.
//
// A cohort is the set of sessions that jointly control a device pane. The GUI
// knows a cohort is a tab; the daemon never learns that, and nothing here
// carries a tab id. It records verified session incarnations, an ordered
// membership, and one representative for attribution.
//
// **Two operations, one method, one revision sequence.** `reconcile` and
// `beginClose` both mutate the same cohort and must order against each other,
// so they share a `(epoch, revision)` key rather than racing across two
// methods with independent numbering. The operation-specific fields are
// optional and validated on arrival, the same shape `pane.input.rotate` uses
// for its two mutually exclusive targets.
//
// No `(sessionId, cap)` handshake: `.validatedGUI`-scoped, so the caller's
// audit token is the authority. A UDS caller must never reach this method at
// all: membership decides who may drive another session's pane, and a close
// verdict decides who inherits its simulator.
//
// `revision` is the client half of the ordering key; the daemon pairs it with
// the monotonic XPC connection id it derives itself. A new transition against
// an existing cohort applies only when its key strictly dominates the stored
// key, which is what makes a GUI restart replaying low revisions harmless; an
// exact `beginClose` retry replays the journalled result instead, for as long
// as the journal entry is retained (the boot-claim lease).

public struct SessionSetCohortParams: Codable, Sendable, Equatable {
    public enum Operation: String, Codable, Sendable, Equatable {
        /// Install or replace a cohort's complete membership, representative,
        /// and pane bindings.
        case reconcile
        /// Commit a close verdict for some members and return the
        /// authoritative outcome the GUI must record before it closes them.
        case beginClose
    }

    public let operation: Operation
    /// The cohort this request addresses. Minted by the GUI, opaque to the
    /// daemon, and stable for the life of the tab it stands for.
    public let cohortId: String
    public let revision: Int

    // MARK: reconcile

    /// Complete ordered membership, replacing rather than amending. Order is
    /// the GUI's nomination sequence; it also decides who inherits when a
    /// member closes before the GUI can renominate.
    public let members: [String]?
    /// Nominated representative. Must appear in `members`; the daemon
    /// validates rather than trusting it.
    public let representative: String?
    /// A prior cohort this one replaces. Naming it is what permits a member to
    /// move between cohorts: the retirement and the placement commit together.
    /// Cohorts not named here are untouched, so restoring one tab never
    /// retires another tab's cohort.
    public let replaces: String?
    /// Pane records to bind to this cohort, each with the admission it is
    /// expected to be at.
    public let bindings: [SessionCohortBinding]?

    // MARK: beginClose

    /// GUI-minted, stable across retries of the *same* close, and never
    /// regenerated for it. The daemon journals its outcome under this id
    /// before replying, so a retry after a lost reply returns the identical
    /// verdict instead of deciding again, for as long as the journal entry
    /// is retained (the boot-claim lease).
    public let transitionId: String?
    /// The members leaving. A subset promotes; the whole membership takes the
    /// terminal mode.
    public let leaving: [String]?
    /// What the user asked to happen to the devices when nothing remains.
    public let mode: PaneCloseMode?

    public init(
        operation: Operation,
        cohortId: String,
        revision: Int,
        members: [String]? = nil,
        representative: String? = nil,
        replaces: String? = nil,
        bindings: [SessionCohortBinding]? = nil,
        transitionId: String? = nil,
        leaving: [String]? = nil,
        mode: PaneCloseMode? = nil
    ) {
        self.operation = operation
        self.cohortId = cohortId
        self.revision = revision
        self.members = members
        self.representative = representative
        self.replaces = replaces
        self.bindings = bindings
        self.transitionId = transitionId
        self.leaving = leaving
        self.mode = mode
    }
}
