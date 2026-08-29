// SPDX-License-Identifier: GPL-3.0-or-later

/// Where a backend obtains the observation that settles rotation.
enum RotationConfirmationSupport: Sendable, Equatable {
    /// The coordinator waits for the backend's ordered display observer.
    case displayObservation
    /// The backend's command reply carries the observed orientation.
    case commandReply
    /// No supported observation path exists.
    case unsupported
}
