// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Reply for `orchestrator.grant` / `orchestrator.revoke`.
///
/// `applied` is whether the batch was accepted and its intended end-state now
/// holds for every target: all-or-none, last-write-wins by the `(epoch,
/// revision)` key. `applied: true` does not by itself imply a mutation: an empty
/// batch, or a revoke of targets already non-live (removed or never created),
/// converges vacuously. `applied: false` means the request did not take effect
/// and nothing changed: for a grant, because its issuing connection had already
/// closed OR its key failed to strictly dominate some target; for a revoke,
/// because its key failed to strictly dominate some live target. Either way the
/// GUI can tell an accepted request from a rejected/stale no-op without
/// inferring it from ordering. (A grant naming a non-live target is a distinct
/// failure: the handler rejects it with `invalidParams`, not `applied: false`.)
public struct OrchestratorGrantResult: Codable, Sendable, Equatable {
    public let applied: Bool

    public init(applied: Bool) {
        self.applied = applied
    }
}
