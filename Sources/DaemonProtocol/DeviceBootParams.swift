// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeviceBootParams: shared `device.boot` request shape.

public struct DeviceBootParams: Codable, Sendable, Equatable {
    public let udid: String
    public let sessionId: String?
    public let cap: String?
    public let claim: BootClaimEvidence?

    public init(
        udid: String,
        sessionId: String? = nil,
        cap: String? = nil,
        claim: BootClaimEvidence? = nil
    ) {
        self.udid = udid
        self.sessionId = sessionId
        self.cap = cap
        self.claim = claim
    }
}
