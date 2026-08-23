// SPDX-License-Identifier: GPL-3.0-or-later
//
// SessionSetCohortResult: authoritative reply to `session.setCohort`.
//
// `applied: false` means the request lost its ordering comparison and the
// daemon mutated nothing. As with `session.setProtectedBatch`, the GUI commits
// presentation state only from an applied reply, and reconciles from a fresh
// authoritative read rather than guessing after a rejection.

public struct SessionSetCohortResult: Codable, Sendable, Equatable {
    /// True iff the daemon committed this request. False means a
    /// higher-keyed write already won, or a replacement was rejected, and
    /// nothing changed.
    public let applied: Bool
    /// Echo of the request's revision, so the GUI can correlate the reply.
    public let revision: Int
    /// Per-pane binding results, present on an applied request that carried
    /// bindings. A refused binding here is not a failure of the call: when
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
        bindings: [SessionCohortBindingResult]? = nil
    ) {
        self.applied = applied
        self.revision = revision
        self.bindings = bindings
    }
}
