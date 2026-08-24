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
    /// A presentation event, not a command receipt. Where it comes from
    /// depends on the pane. One observing its display emits for any cause,
    /// including a rotation from outside deviceterm, and stays silent when
    /// an orientation-locked app answers a rotate without moving the
    /// framebuffer. One with no display source emits from a performed
    /// rotate instead, so external rotations are invisible to it and a
    /// locked app turns it when it shouldn't.
    case orientationChanged(
        paneId:
        UUID,
        orientation: Orientation
        )
}
