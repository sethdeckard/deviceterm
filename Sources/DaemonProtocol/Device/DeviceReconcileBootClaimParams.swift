// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeviceReconcileBootClaimParams: validated-GUI reconciliation request for a
// pending simulator boot attribution.

public struct DeviceReconcileBootClaimParams: Codable, Sendable, Equatable {
    public let claim: BootClaimEvidence
    public let sessionId: String?

    public init(claim: BootClaimEvidence, sessionId: String?) {
        self.claim = claim
        self.sessionId = sessionId
    }
}
