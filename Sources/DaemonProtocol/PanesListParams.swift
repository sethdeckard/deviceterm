// SPDX-License-Identifier: GPL-3.0-or-later
//
// PanesListParams: wire shape for `panes.list`.
//
// Session-scoped discovery. `(sessionId, cap)` is the cap-validated
// handshake the daemon uses to confirm the caller owns the session
// whose panes are being listed.

public struct PanesListParams: Codable, Sendable {
    public let sessionId: String
    public let cap: String

    public init(sessionId: String, cap: String) {
        self.sessionId = sessionId
        self.cap = cap
    }
}
