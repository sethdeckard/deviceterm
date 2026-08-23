// SPDX-License-Identifier: GPL-3.0-or-later
//
// SessionCohortBinding: one pane record a cohort reconcile wants bound to
// itself, and the attachment it expects that record to be at.
//
// Cohort reconciliation is a separate call from `device.attach`, so a pane
// created by an attach that raced the reconcile may already have moved on. The
// expected attachment is the fence that catches it: the daemon binds only when
// the record is still at the admission the GUI was looking at.
//
// The attachment is a *record admission counter*, not a session incarnation and
// not the ordering revision. It advances on a fresh create, a revisioned
// same-owner re-attach, and an ownership transfer, which is exactly the set of
// events after which a stale binding would be wrong.

public struct SessionCohortBinding: Codable, Sendable, Equatable {
    /// The pane record to bind, as a UUID string.
    public let paneId: String
    /// The record admission this binding was computed against. A record that
    /// has advanced past it is refused rather than bound.
    public let expectedAttachment: UInt64

    public init(paneId: String, expectedAttachment: UInt64) {
        self.paneId = paneId
        self.expectedAttachment = expectedAttachment
    }
}

/// Per-pane result of a reconcile's binding half.
///
/// Whether a refusal is fatal depends on the operation, and the daemon decides
/// that rather than the caller: adding panes to a live cohort reports refusals
/// and commits the rest, while a reconcile that *replaces* a cohort rejects
/// wholesale if any binding is refused. See `SessionSetCohortResult`.
public struct SessionCohortBindingResult: Codable, Sendable, Equatable {
    public let paneId: String
    /// True when the record is now bound to the cohort. False means the
    /// pane was unavailable, its attachment did not match, or it already
    /// named another cohort; the GUI retries from a fresh snapshot.
    public let bound: Bool

    public init(paneId: String, bound: Bool) {
        self.paneId = paneId
        self.bound = bound
    }
}
