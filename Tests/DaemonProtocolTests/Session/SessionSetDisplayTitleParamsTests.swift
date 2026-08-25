// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

// The clear has to be distinguishable on the wire from "no update", or a
// title that normalizes to nothing would leave the previous label cached
// forever. Swift's synthesized encoder omits a nil Optional, so this shape
// encodes `title` explicitly.

@Test
func encodesAClearAsAnExplicitNull() throws {
    let encoded = try JSONEncoder().encode(
        SessionSetDisplayTitleParams(sessionId: "S1", title: nil)
    )
    let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    #expect(object?.keys.contains("title") == true)
    #expect(object?["title"] is NSNull)
}

@Test
func roundTripsATitle() throws {
    let params = SessionSetDisplayTitleParams(sessionId: "S1", title: "vim foo.swift")
    let decoded = try JSONDecoder().decode(
        SessionSetDisplayTitleParams.self,
        from: try JSONEncoder().encode(params)
    )
    #expect(decoded == params)
}

@Test
func decodesAnAbsentTitleAsNoTitle() throws {
    // Tolerant on the way in: an absent key and a null can only mean the
    // same thing, and a client that omits it shouldn't be a decode failure.
    let json = Data(#"{"sessionId":"S1"}"#.utf8)
    let decoded = try JSONDecoder().decode(SessionSetDisplayTitleParams.self, from: json)
    #expect(decoded.sessionId == "S1")
    #expect(decoded.title == nil)
}

@Test
func carriesNoCapabilityOnTheWire() throws {
    // `.validatedGUI`-scoped: the audit token is the authority, so a
    // credential must never appear in this shape.
    let encoded = try JSONEncoder().encode(
        SessionSetDisplayTitleParams(sessionId: "S1", title: "t")
    )
    let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    #expect(object?["cap"] == nil)
    #expect(object?.count == 2)
}
