// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A per-request provenance snapshot for a session: its captured owner, its
/// current terminal anchor, and its lifecycle admission. Returned by
/// `SessionProvenanceLookup` and fed to the `ProvenanceMatcher`. Keeping them
/// together means the authenticate gate and per-request scope re-check share
/// one lookup. `admission` gates a request *before* the provenance verdict:
/// a `.notReady` id is retryable regardless of provenance, and a `.ready`
/// id's incarnation rides into the principal so a parked request can't pass a
/// later incarnation's producer gate. Defaults to `.ready(incarnation: nil)`
/// so a synthetic test snapshot is admissible and un-pinned unless it says
/// otherwise.
public struct SessionProvenanceSnapshot: Sendable, Equatable {
    public let owner: OwnerProcessIdentity?
    public let anchor: TerminalAnchor?
    public let admission: SessionAdmission

    public init(
        owner: OwnerProcessIdentity?,
        anchor: TerminalAnchor?,
        admission: SessionAdmission = .ready(incarnation: nil)
    ) {
        self.owner = owner
        self.anchor = anchor
        self.admission = admission
    }
}
