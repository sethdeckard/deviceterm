// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import DaemonProtocol
import Foundation
import IOSurface
import os
import SurfaceTrace

/// A token for close cleanup that continues asynchronously, because a gesture
/// is still finishing or a held contact's release has to be retried. Awaitable,
/// so a caller can tell when the pane's device is free again.
public struct PaneCloseDeferral: Sendable {
    public let paneId: UUID
}
