// SPDX-License-Identifier: GPL-3.0-or-later

/// Reply to `session.restoreBatch`: the count and ids the daemon now
/// holds live for this inventory, so the GUI can confirm the set it
/// pushed. On success the whole batch committed atomically (all-or-none);
/// a malformed / duplicate / conflicting batch is rejected in full with
/// `invalidParams` and nothing is mutated.
public struct SessionRestoreBatchResult: Codable, Sendable, Equatable {
    public let restoredCount: Int
    public let sessionIds: [String]

    public init(restoredCount: Int, sessionIds: [String]) {
        self.restoredCount = restoredCount
        self.sessionIds = sessionIds
    }
}
