// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import DaemonProtocol
import Foundation
import IOSurface
import os
import SurfaceTrace

public struct PaneCreateResult: Sendable, Equatable {
    public let paneId: UUID
    /// Identifies this admission of the pane. A close that carries it is
    /// refused once a later admission has replaced it, so a close issued
    /// before a re-attach can't retire the record the re-attach handed back.
    public let attachment: UInt64
    /// Logical-point-to-pixel ratio for the device's display. The
    /// daemon doesn't compute this directly: the GUI derives an
    /// approximation from `family` for the four size presets, since
    /// the wire carries `pixelWidth`/`pixelHeight` (the values
    /// actually needed for sizing math) and CoreSimulator doesn't
    /// expose the device's native @x scale on `SimDeviceType`. Kept
    /// as a wire field for forward compatibility; current daemons
    /// emit `1.0`.
    public let scale: Double?
    /// Coarse device family (`watch`/`phone`/`pad`/`tv`/`unknown`) so
    /// the GUI can size the pane for the device: every attach path
    /// gets it from the daemon rather than the caller's context.
    public let family: String
    /// Crockford base32 short_id (6 chars, lowercased). Always
    /// non-nil: daemon mints with `ShortID.generate()` plus
    /// collision retry inside the coordinator's actor.
    public let shortId: String
    /// Optional human-set name. Nil at create while the shipped
    /// `pane rename` command remains unimplemented.
    public let name: String?
    /// Human-readable device type from `SimDeviceType.name`
    /// (e.g. "Apple Watch Ultra 3 (49mm)"). Nil only if the bridge
    /// can't read the property: the GUI falls back to name-only
    /// in that case.
    public let deviceType: String?
    /// Native pixel dimensions of the device's display, read from
    /// `SimDisplayHandle.displaySize`. Nil when the renderable
    /// hasn't bound a surface yet; the GUI falls back to family-
    /// default sizing in that case.
    public let pixelWidth: Int?
    /// Pairs with `pixelWidth`.
    public let pixelHeight: Int?
    /// Per-pane device-control capabilities, the wire projection of
    /// the backend's capability set. Every attach path gets it from the
    /// daemon's response so clients gate affordances per pane.
    public let capabilities: PaneCapabilities
    /// Backend-neutral identity + kind discriminator (`.sim` vs
    /// `.device`).
    public let target: PaneTarget
}
