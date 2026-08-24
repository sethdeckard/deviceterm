// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import DaemonProtocol
import Foundation
import IOSurface
import os
import SurfaceTrace

/// Attribution and controller membership for the live pane mirroring a
/// given device. Backs the `devices.list` aggregate roster's attachment
/// annotation. Carries the full `PaneTarget` (not just its `.key` string)
/// so the roster matches on **kind + id**: a sim and a physical device that
/// share id text are never cross-annotated.
public struct PaneOwnership: Sendable, Equatable {
    public let target: PaneTarget
    /// The session attributed to this pane: its live cohort's
    /// representative, or the record's own session when unbound.
    /// Attribution, not authority.
    public let sessionId: UUID
    /// Every member permitted to drive the pane. The roster's visibility test
    /// runs against this, so a caller sharing a protected tab with the
    /// attaching terminal still sees its own tab's device as attached.
    ///
    /// Carries incarnations rather than bare ids, matching authorization,
    /// events and `panes.list`. Reducing to ids here would let a restored
    /// session see a previous incarnation's device as attached and read its
    /// owner annotation, even though it can neither list nor drive that pane.
    public let controllingMembers: Set<CohortMember>
    public let paneShortId: String
    public let paneId: UUID

    /// Sim UDID or physical deviceId: the string clients correlate with
    /// `panes.list`. Kind-qualified matching keys on `target`, not this.
    public var targetKey: String { target.key }

    public init(
        target: PaneTarget,
        sessionId: UUID,
        paneShortId: String,
        paneId: UUID,
        controllingMembers: Set<CohortMember>? = nil
    ) {
        self.target = target
        self.sessionId = sessionId
        self.controllingMembers = controllingMembers
            ?? [CohortMember(sessionId: sessionId, incarnation: 0)]
        self.paneShortId = paneShortId
        self.paneId = paneId
    }
}
