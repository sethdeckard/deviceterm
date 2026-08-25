// SPDX-License-Identifier: GPL-3.0-or-later
//
// CohortCloseOutcome: the authoritative verdict for one closing session's
// devices, returned by `session.setCohort`'s `beginClose` operation.
//
// A bare `PaneCloseMode` can only say "detach" or "shut down", which cannot
// express the case a shared tab creates: the session is leaving but its
// siblings remain, so the device changes hands rather than going away. The
// daemon decides the verdict (it is the only side holding the cohort) and
// hands it back, so the GUI's boot-claim tombstone and the daemon's record
// the same answer instead of each deriving one.
//
// Deliberately NOT folded into `BootClaimDisposition`. That enum is
// `String`-raw and rides the boot-claim wire; adding an associated value would
// break its raw-value conformance to express something no boot-claim producer
// ever sends. A promotion is a fact about a *session close*, not about the
// claim's own disposition.

/// The authoritative verdict for one closing session's devices.
public enum CohortCloseOutcome: Sendable, Codable, Equatable {
    /// Siblings remain: `successor` inherits the closing session's panes,
    /// simulator ownership, and any boot claim still converging. The
    /// simulator keeps running and stays attributed.
    case promote(successor: String)
    /// Nothing remains, and the user asked to keep the simulator running.
    case detach
    /// Nothing remains, and the user asked to shut the simulator down.
    case shutdown

    /// The session inheriting from this outcome, or nil when the outcome is
    /// terminal.
    public var successor: String? {
        guard case let .promote(successor) = self else { return nil }
        return successor
    }
}
