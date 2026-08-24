// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Who a published event is addressed to. **Daemon-internal, never
/// crosses the wire** (no Codable); resolved to a set of subscribers at
/// publish time. `.session` reaches that session's subscribers (and the
/// validated GUI peer, which spans sessions); `.sessions` reaches any of
/// several; `.everyone` reaches every subscriber. Reusing this rather than
/// putting a routing field on the wire `DaemonEvent` keeps the audience
/// decision off the wire.
enum EventAudience: Sendable, Equatable {
    case session(UUID)
    /// Every member of a pane's cohort. A pane's lifecycle events reach all
    /// the sessions permitted to drive it, not just the one that attached it,
    /// so a sibling terminal is not left subscribed to a pane it never hears
    /// about. Publishing per-member instead would deliver N events to the GUI
    /// peer, which every audience already reaches.
    ///
    /// Carries incarnations rather than bare ids. A restored session keeps its
    /// UUID, and matching on the id alone would stream a previous
    /// incarnation's pane events to it even though every control call
    /// correctly refuses.
    case sessions(Set<CohortMember>)
    case everyone
}
