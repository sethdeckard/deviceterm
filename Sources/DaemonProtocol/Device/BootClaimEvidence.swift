// SPDX-License-Identifier: GPL-3.0-or-later

/// Causal evidence for one DeviceTerm-originated simulator
/// boot. The monotonic lease is expressed as remaining time so it can cross a
/// process boundary without comparing unrelated clocks.
public struct BootClaimEvidence: Codable, Sendable, Equatable {
    public static let maximumLeaseMilliseconds: UInt64 = 300_000

    public let attemptId: String
    public let udid: String
    public let source: BootClaimSource
    public let observedState: BootClaimObservedState
    public let disposition: BootClaimDisposition
    public let remainingLeaseMilliseconds: UInt64

    public init(
        attemptId: String,
        udid: String,
        source: BootClaimSource,
        observedState: BootClaimObservedState,
        disposition: BootClaimDisposition = .attach,
        remainingLeaseMilliseconds: UInt64 = Self.maximumLeaseMilliseconds
    ) {
        self.attemptId = attemptId
        self.udid = udid
        self.source = source
        self.observedState = observedState
        self.disposition = disposition
        self.remainingLeaseMilliseconds = remainingLeaseMilliseconds
    }
}
