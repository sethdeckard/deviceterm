// SPDX-License-Identifier: GPL-3.0-or-later

/// Reply to `device.restoreOwnership`: the ownership claims the daemon
/// accepted, lowercased and sorted.
///
/// A claim is absent when the daemon could not take it, which is not an error:
/// the simulator is not Booted, or the daemon already holds a conflicting
/// attribution for it. An otherwise admissible claim naming a session that is
/// no longer live IS present, restored without attribution. The caller learns
/// what stuck rather than being told the batch failed.
public struct DeviceRestoreOwnershipResult: Codable, Sendable, Equatable {
    public let restoredCount: Int
    public let udids: [String]

    public init(restoredCount: Int, udids: [String]) {
        self.restoredCount = restoredCount
        self.udids = udids
    }
}
