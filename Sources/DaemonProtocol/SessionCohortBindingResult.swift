// SPDX-License-Identifier: GPL-3.0-or-later

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
