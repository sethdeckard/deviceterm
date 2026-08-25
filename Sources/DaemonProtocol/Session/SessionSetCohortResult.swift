// SPDX-License-Identifier: GPL-3.0-or-later

/// Authoritative reply to `session.setCohort`.
///
/// `applied: false` means validation or ordering rejected the request; cohort
/// membership and pane bindings did not change. As with
/// `session.setProtectedBatch`, the GUI commits
/// presentation state only from an applied reply, and reconciles from a fresh
/// authoritative read rather than guessing after a rejection.
///
/// For `beginClose`, `outcome` is the whole point of the call: it is the
/// verdict the GUI records in its own boot-claim tombstone before it closes
/// the sessions, so both layers act on one decision instead of two guesses.
/// It is journalled under the request's `transitionId` **before** this reply
/// is sent, so a retry after a lost reply returns this same value even though
/// the cohort has moved on, for as long as the journal entry is retained
/// (the boot-claim lease).
public struct SessionSetCohortResult: Codable, Sendable, Equatable {
    /// True when the daemon committed this request, or replayed its
    /// retained `beginClose` journal entry. False means validation or
    /// ordering rejected it, and cohort membership and pane bindings did
    /// not change.
    public let applied: Bool
    /// Echo of the request's revision, so the GUI can correlate the reply.
    public let revision: Int
    /// `beginClose` only: the authoritative verdict for the leaving members.
    /// Nil on a reconcile, and nil on a rejected `beginClose` (there is no
    /// verdict to record when nothing committed).
    public let outcome: CohortCloseOutcome?
    /// Per-pane binding results: present on an applied reconcile, one entry
    /// per requested or replacement-swept pane, empty when none were
    /// processed. A refused binding here is not a failure of the call: when
    /// the request only adds panes to a live cohort the rest of the commit
    /// stands and the GUI retries that pane. A request that *replaces* a
    /// cohort never reports a partial result, because a replacement is
    /// rejected outright if any binding is refused; leaving a pane pointing
    /// at a retired cohort would strand it, correctly refusing every session
    /// that tried to drive it.
    public let bindings: [SessionCohortBindingResult]?

    public init(
        applied: Bool,
        revision: Int,
        outcome: CohortCloseOutcome? = nil,
        bindings: [SessionCohortBindingResult]? = nil
    ) {
        self.applied = applied
        self.revision = revision
        self.outcome = outcome
        self.bindings = bindings
    }
}
