// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import DaemonProtocol
import Foundation
import IOSurface
import os
import SurfaceTrace

public enum PaneEvent: Sendable {
    /// A new surface is available for `paneId`. `sequence` is the
    /// per-pane monotonic counter assigned by the coordinator; it
    /// pairs the JSON evt the subscription stream emits with the
    /// side-band surface payload (`RetainedSurface`) the
    /// `PaneSubscriptionRegistry` delivers separately on XPC
    /// subscribers. The same number lands in both places, so the
    /// receiver can correlate them. Restarts at 1 on daemon
    /// relaunch.
    case surfaceChanged(
        paneId:
        UUID,
        sequence: UInt64
        )
    case stateChanged(
        paneId:
        UUID,
        state: PaneLifecycle
        )
    /// The pane's presentation orientation changed, so subscribers
    /// re-render, re-fit the bezel, and re-map input against it.
    ///
    /// A presentation event, not a command receipt. A Simulator emits from
    /// display observation, including a rotation from outside DeviceTerm, and
    /// stays silent when an orientation-locked app leaves the framebuffer in
    /// place. A physical device emits from a valid rotation reply, including a
    /// non-target observation, so an external rotation remains invisible.
    case orientationChanged(
        paneId:
        UUID,
        orientation: Orientation
        )
}
