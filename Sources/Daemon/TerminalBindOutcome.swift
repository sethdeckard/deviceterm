// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Outcome of a `bind`. The handler maps `.applied` to success and the other
/// cases to distinct errors.
public enum TerminalBindOutcome: Sendable, Equatable {
    /// Bound: a fresh binding, or an idempotent re-bind of the identical
    /// anchor.
    case applied
    /// The live session already has a DIFFERENT terminal anchor. Immutable:
    /// rejected; freeing requires the session to be removed first.
    case conflict
    /// The issuing GUI connection has been retired (closed). Rejected so a
    /// bind that suspended before the close can't resurrect an anchor.
    case issuerRetired
    /// The target session is not a live member (never registered, or removed
    /// while the bind was in flight). Rejected so a delayed bind can't
    /// recreate an anchor for a dead session.
    case sessionNotLive
}
