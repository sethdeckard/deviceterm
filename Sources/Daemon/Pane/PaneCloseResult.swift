// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import DaemonProtocol
import Foundation
import IOSurface
import os
import SurfaceTrace

/// The cross-coordinator work a close has to run, which `PaneCoordinator` owns
/// neither `DeviceCoordinator` nor `PhysicalDeviceCoordinator` to do itself.
///
/// Passed in rather than handed back, because it runs inside the coordinator's
/// target reservation on both the inline and deferred paths. Returning it would
/// let a re-create attach as soon as the backend was down, and the pending
/// shutdown would then kill the device out from under the new pane.
public typealias PaneExternalCleanup = @Sendable (PaneCloseOutcome) async -> (any Error)?

/// What a close hands back: the ack, a deferral when cleanup continues past it,
/// and whatever the external cleanup reported when it ran inline.
public struct PaneCloseResult: Sendable {
    public let outcome: PaneCloseOutcome
    public let deferral: PaneCloseDeferral?
    /// What the external cleanup reported, for a close that ran it inline.
    /// Nil on the deferred path: the ack is long gone by the time it runs.
    public let cleanupError: (any Error)?

    public init(
        outcome: PaneCloseOutcome,
        deferral: PaneCloseDeferral?,
        cleanupError: (any Error)? = nil
    ) {
        self.outcome = outcome
        self.deferral = deferral
        self.cleanupError = cleanupError
    }
}
