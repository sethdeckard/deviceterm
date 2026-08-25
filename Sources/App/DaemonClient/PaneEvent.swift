// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Decoded events from a `pane.subscribe` stream.
///
/// The XPC transport delivers two messages per surface update: the JSON
/// `surface.changed` evt (carrying `paneId` + `sequence`) and a side-band
/// surface payload carrying the subscription token, the `leased`/`leaseEpoch`
/// overlay, and an XPC object that resolves to an `IOSurfaceRef`. The
/// `XPCDaemonConnection` correlates the pair by `(paneId, sequence, token)`
/// and synthesizes a single `surfaceChanged(_, SurfaceLease?)` event for the
/// VM. The lease is nil when the side-band payload was missing (timeout /
/// reorder); the view holds the previous surface in that case.
enum PaneEvent: Sendable {
    /// The lease is nil on a JSON-only frame (timeout / reorder, the view
    /// keeps its previous surface) and always nil over UDS. A leased device
    /// frame carries a leased `SurfaceLease` (use-count bumped, released on ARC
    /// deinit → the daemon frees the slot); an unleased frame (every
    /// simulator frame, and every device frame when `DEVICETERM_SURFACE_LEASES`
    /// is off) carries a `SurfaceLease` with no use-count and no ack.
    case surfaceChanged(SurfaceChangedEvent, SurfaceLease?)
    case stateChanged(StateChangedEvent)
    case orientationChanged(OrientationChangedEvent)
}
