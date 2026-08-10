// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Parameters for `orchestrator.grant` and `orchestrator.revoke`.
///
/// `sessionIds` is a typed `[UUID]`, so a malformed identifier fails
/// decoding and the request is rejected `invalidParams` before any mutation.
/// Grant/revoke are all-or-none, never a partial application. On the wire
/// this is still a JSON array of UUID strings.
///
/// `revision` is a monotonically increasing value from the issuing GUI; the
/// daemon pairs it with a server-derived epoch (the XPC connection id) into
/// the ordering key that makes grant/revoke last-write-wins regardless of
/// the order the daemon's non-FIFO inbound tasks happen to run in.
///
/// The issuing connection is derived server-side from the dispatch context,
/// never carried here, so a payload can't claim to act for another
/// connection.
public struct OrchestratorGrantParams: Codable, Sendable, Equatable {
    public let sessionIds: [UUID]
    public let revision: Int

    public init(sessionIds: [UUID], revision: Int) {
        self.sessionIds = sessionIds
        self.revision = revision
    }
}
