// SPDX-License-Identifier: GPL-3.0-or-later
//
// SessionSetDisplayTitleParams: wire shape for `session.setDisplayTitle`,
// the validated-GUI push of a tab's normalized display title.
//
// No `(sessionId, cap)` handshake. The method is `.validatedGUI`-scoped,
// so the peer's audit token already carries authority across every
// session; a capability would add none, and threading one through the
// wire shape would break the convention that authentication is
// connection-scoped rather than per-call.
//
// `title` is Optional and a **null title is the clear operation**, not a
// no-op. Normalization can turn a non-empty OSC title into nothing (all
// bidi controls, or a first grapheme already over budget); if that were
// sent as "no update", a previously cached valid title would outlive the
// value that replaced it, and the tab would carry the superseded label
// until some later title update, session close, or daemon restart.
// So the clear is transmitted explicitly: `encode(to:)` writes a JSON
// null rather than omitting the key, while decoding tolerates both a null
// and an absent key, since either can only mean "no title".

public struct SessionSetDisplayTitleParams: Codable, Sendable, Equatable {
    public let sessionId: String
    public let title: String?

    public init(sessionId: String, title: String?) {
        self.sessionId = sessionId
        self.title = title
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionId, forKey: .sessionId)
        // `encode`, not `encodeIfPresent`: the null must reach the wire.
        try container.encode(title, forKey: .title)
    }
}
