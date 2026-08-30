// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import DaemonProtocol
import Foundation
import IOSurface
import os
import SurfaceTrace

/// One sim pane belonging to a session, the `panes.list` row shape
/// and the CLI's pane-resolution unit.
///
/// `shortId` + `name` are the three-layer identifier model's
/// per-pane fields; the daemon mints `shortId` at create time via
/// `ShortID.generate()` with collision retry against the live pane set
/// and leaves `name` nil while the shipped `pane rename` command remains
/// unimplemented.
public struct PaneInfo: Sendable, Equatable {
    public let paneId: UUID
    public let udid: String
    public let state: PaneLifecycle
    /// Coarse device family (`watch`/`phone`/`pad`/`tv`/`unknown`):
    /// see `DeviceFamily`.
    public let family: String
    public let shortId: String
    public let name: String?
    /// Per-pane device-control capabilities (the wire projection of the
    /// backend's capability set), cached at create so it survives the
    /// pane's shutdown.
    public let capabilities: PaneCapabilities
    /// Backend-neutral identity + kind discriminator.
    public let target: PaneTarget
    /// Whether the pane's current backend can produce confirmed orientation
    /// evidence.
    public let orientationConfirmationSupported: Bool
    /// Latest confirmed orientation. Simulator panes derive it from
    /// framebuffer observation; physical panes derive it from a completed
    /// relay reply. Nil means no confirmed observation is available.
    public let orientation: Orientation?
    /// Current rendered surface metadata. Nil before a surface exists.
    public let surface: PanesListEntry.Surface?
}
