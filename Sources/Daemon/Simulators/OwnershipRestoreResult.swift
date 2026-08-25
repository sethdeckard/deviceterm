// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import DaemonProtocol
import Foundation

/// What `DeviceCoordinator.restoreOwnership` did: what to report, and which
/// entries it wrote, whose attribution may still need demoting after the
/// commit. Split so a caller revisits only what it added.
public struct OwnershipRestoreResult: Sendable, Equatable {
    /// Every normalized udid whose requested ownership and attribution now
    /// match, including ones that already matched before the call and ones
    /// claimed with no attribution. This is what the caller reports back: it
    /// answers "did the claim take", not "did you write it".
    public let attributed: Set<String>
    /// Only the entries this call wrote, keyed by normalized udid, with the
    /// attribution it wrote (nil for an unattributed one). It identifies
    /// exactly which newly written attributions may still need demoting; the
    /// ownership itself stands either way.
    public let written: [String: UUID?]

    public init(attributed: Set<String>, written: [String: UUID?]) {
        self.attributed = attributed
        self.written = written
    }
}
