// SPDX-License-Identifier: GPL-3.0-or-later

/// Wire shape for `panes.list`.
///
/// Session-scoped discovery. The daemon validates `(sessionId, cap)` and then
/// requires `sessionId` to equal the connection's own provenance-checked
/// session, so the cap is one factor rather than proof the caller owns the
/// session whose panes are being listed.
public struct PanesListParams: Codable, Sendable {
    public let sessionId: String
    public let cap: String

    public init(sessionId: String, cap: String) {
        self.sessionId = sessionId
        self.cap = cap
    }
}
