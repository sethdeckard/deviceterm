// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// A backend's contribution to one rotation result.
///
/// Simulator dispatch is one-way and becomes conclusive only after the
/// coordinator's display observer reports the target. Physical-device replies
/// can settle the request inside the backend.
enum BackendRotationOutcome: Sendable, Equatable {
    /// The command was sent; the coordinator must await display observation.
    ///
    /// `target` is the device orientation asked for and `display` the reading
    /// that confirms it. They differ only on a foldable's inner panel, which
    /// reads a quarter turn off the device.
    case dispatched(target: Orientation, display: Orientation)
    /// The backend observed the requested orientation.
    case confirmed(target: Orientation, observed: Orientation)
    /// The backend observed a different result or exhausted its bounded work.
    case unconfirmed(target: Orientation?, observed: Orientation?)
    /// The backend rejected a valid rotation operation.
    case refused(target: Orientation?)
    /// Ownership or backend liveness disappeared before the operation settled.
    case unavailable(target: Orientation?)
    /// The backend cannot supply a conclusive observation.
    case confirmationUnsupported(target: Orientation?)
}
