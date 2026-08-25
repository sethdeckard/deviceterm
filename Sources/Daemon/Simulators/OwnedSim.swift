// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import DaemonProtocol
import Foundation

/// Plain `Sendable` snapshot of one owned, booted sim: exactly the
/// fields the status-item shutdown menu needs to list and act on it.
/// Decoupled from `CSBDeviceInfo` so the menu-model logic
/// (`statusMenuEntries`) stays pure and unit-testable without
/// constructing CoreSimulator types.
public struct OwnedSim: Sendable, Equatable {
    public let udid: String
    public let name: String
    public let runtimeIdentifier: String
    /// Session attributed to this sim per `DeviceCoordinator.ownership`.
    /// nil when the owned sim has no recorded attribution. The status-item
    /// menu groups a nil or unresolvable attribution under "Unlinked", and a
    /// live one under its session.
    public let sessionId: UUID?

    public init(
        udid: String,
        name: String,
        runtimeIdentifier: String,
        sessionId: UUID? = nil
    ) {
        self.udid = udid
        self.name = name
        self.runtimeIdentifier = runtimeIdentifier
        self.sessionId = sessionId
    }
}
