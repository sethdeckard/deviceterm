// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// A backend's answer to laying the device face up or face down.
///
/// Separate from `BackendRotationOutcome` because nothing on the display
/// settles it: a device laid flat keeps its interface orientation, so the
/// coordinator's display observer has nothing to wait for.
enum BackendFlatOrientationOutcome: Sendable, Equatable {
    /// The device reported the requested flat orientation.
    case confirmed
    /// The request was sent and the device offers nothing to confirm it
    /// against.
    case dispatched
    /// The device reported something else afterwards. `observed` is the flat
    /// orientation it reported, nil when it reported a non-flat one.
    case unconfirmed(observed: FlatOrientation?)
    /// The backend does not lay a device flat.
    case refused
    /// Ownership moved before the request was sent.
    case unavailable
}
