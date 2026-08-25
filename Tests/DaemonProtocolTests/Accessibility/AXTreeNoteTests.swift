// SPDX-License-Identifier: GPL-3.0-or-later

@testable import DaemonProtocol
import Foundation
import Testing

// AXTreeNote raw values are part of the wire: agents read them as
// the literal string at `tree["note"]`. Pin the values so a rewording
// of the human-readable message is a deliberate wire-version change,
// not a stealth break of agents that compare against the constant.

@Test
func watchOSEnumerationUnsupportedRawValueIsStable() {
    // Pinned literal, because the note text gets included in tree
    // responses. Agents that pin the string will see any rephrase
    // as a wire-version change; they should match by enum case via
    // Codable, not by string equality. The current text leads with
    // `ax sweep` (the better recommendation) over `ax point`.
    #expect(
        AXTreeNote.watchOSEnumerationUnsupported.rawValue ==
        // swiftlint:disable:next line_length
        "AX tree enumeration is unsupported on watchOS; use 'deviceterm ax sweep' to grid-walk via objectAtPoint, or 'deviceterm ax point <x> <y>' for a single element"
    )
}

@Test
func decodesFromRawString() throws {
    // Quote the raw value so JSONDecoder sees a JSON string literal.
    let raw = AXTreeNote.watchOSEnumerationUnsupported.rawValue
    let json = Data("\"\(raw)\"".utf8)
    let note = try JSONDecoder().decode(AXTreeNote.self, from: json)
    #expect(note == .watchOSEnumerationUnsupported)
}
