// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The result of an `automation.grant` batch.
enum GrantOutcome: Sendable, Equatable {
    /// Applied: every target was a live session and the key dominated.
    case applied
    /// No mutation: a stale (non-dominating) key, or the issuing connection
    /// has closed. The caller reports `applied: false`.
    case notApplied
    /// A target is not a live session (never created, or already removed).
    /// The caller rejects the whole batch with `invalidParams`.
    case sessionNotLive
}
