// SPDX-License-Identifier: GPL-3.0-or-later

/// The daemon's outcome for one `pane.input.rotate` request.
///
/// `ok` is true only for `confirmed`. Optional orientations let failures
/// report as much as the backend observed without inventing a value, and
/// `deadlineMs` appears only when the daemon's confirmation wait expired.
public struct RotateResult: Codable, Sendable, Equatable {
    /// How the rotation request settled.
    public enum Status: String, Codable, Sendable, Equatable {
        /// The backend observed the requested absolute target.
        case confirmed
        /// The request was not admitted, expired, or observed a non-target result.
        case unconfirmed
        /// The daemon or backend cannot observe a rotation outcome.
        case confirmationUnsupported
        /// The pane's backend does not accept rotation.
        case refused
        /// The pane or its backend disappeared before confirmation.
        case unavailable
    }

    /// A machine-readable refinement for a result that callers may handle
    /// without conflating it with every other outcome sharing the status.
    public enum Reason: String, Codable, Sendable, Equatable {
        /// The pane already has the maximum admitted rotations outstanding.
        case queueFull
    }

    private enum CodingKeys: String, CodingKey {
        case success = "ok"
        case status
        case targetOrientation
        case observedOrientation
        case deadlineMs
        case reason
    }

    public let success: Bool
    public let status: Status
    /// The absolute orientation the request resolved to, when known.
    public let targetOrientation: Orientation?
    /// The last orientation the backend confirmed, when available.
    public let observedOrientation: Orientation?
    /// The expired confirmation deadline in milliseconds, when applicable.
    public let deadlineMs: Int?
    /// A command-specific refinement of the status, when one applies.
    public let reason: Reason?

    public init(
        success: Bool,
        status: Status,
        targetOrientation: Orientation?,
        observedOrientation: Orientation?,
        deadlineMs: Int? = nil,
        reason: Reason? = nil
    ) {
        self.success = success
        self.status = status
        self.targetOrientation = targetOrientation
        self.observedOrientation = observedOrientation
        self.deadlineMs = deadlineMs
        self.reason = reason
    }
}
