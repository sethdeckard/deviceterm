// SPDX-License-Identifier: GPL-3.0-or-later

/// Current daemon disposition of one simulator
/// boot attribution attempt.
public struct DeviceReconcileBootClaimResult: Codable, Sendable, Equatable {
    public let attemptId: String
    public let udid: String
    public let status: BootClaimStatus
    public let sessionId: String?

    public init(
        attemptId: String,
        udid: String,
        status: BootClaimStatus,
        sessionId: String?
    ) {
        self.attemptId = attemptId
        self.udid = udid
        self.status = status
        self.sessionId = sessionId
    }
}
