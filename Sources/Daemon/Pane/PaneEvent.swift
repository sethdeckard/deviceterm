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
    /// A foldable device's hinge moved, in degrees, `0` shut and `180` flat.
    ///
    /// An observation rather than a command receipt: the daemon watches the
    /// hinge, so a fold driven from Device Hub or from another tab publishes
    /// here as well as one this daemon dispatched. A device with one panel
    /// never emits.
    case hingeChanged(
        paneId:
        UUID,
        degrees: Double,
        spansHinge: Bool
        )
    /// A foldable device's pane moved onto another panel.
    ///
    /// Carries the panel's identity and shape, so a subscriber can draw the
    /// right panel and capture from it. Published from the display's own
    /// binding rather than with a hinge reading, so it arrives even when the
    /// hinge cannot be read. A device with one panel never emits.
    case panelChanged(paneId: UUID, panel: BoundPanel)
    /// Whether the pane's input is reaching its device changed.
    ///
    /// Worked out from the backend's transport and the pane's contact lane
    /// when either reports a change, so a refusal the caller never sees, such
    /// as the GUI dropping a lane refusal, still reaches the pane.
    case inputChanged(
        paneId:
        UUID,
        health: InputHealth
        )
}
