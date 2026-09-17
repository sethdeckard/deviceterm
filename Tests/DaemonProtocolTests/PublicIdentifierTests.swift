// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

// Tests lowercase UUID formatting and exact preservation of non-UUID
// identifiers.

@Test
func rendersAUUIDInThePublishedForm() throws {
    let id = try #require(UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000"))
    #expect(PublicIdentifier.string(id) == "550e8400-e29b-41d4-a716-446655440000")
}

@Test("canonicalizes whatever case it is handed", arguments: [
    "550E8400-E29B-41D4-A716-446655440000",
    "550e8400-e29b-41d4-a716-446655440000",
    "550e8400-E29B-41d4-A716-446655440000"
])
func canonicalizesAnyCasing(raw: String) {
    #expect(PublicIdentifier.canonicalized(raw) == "550e8400-e29b-41d4-a716-446655440000")
}

/// Running the result back through must not move it, or an ingest boundary
/// that canonicalizes twice would not be safe to add.
@Test
func canonicalizationIsIdempotent() {
    let once = PublicIdentifier.canonicalized("550E8400-E29B-41D4-A716-446655440000")
    #expect(PublicIdentifier.canonicalized(once) == once)
}

/// A physical CoreDevice id belongs to `devicectl` and keeps the uppercase
/// form that tool reports. It is not UUID-shaped, so it must pass through
/// byte for byte rather than being lowercased along with ours.
@Test
func passesThroughAPhysicalDeviceIdentifier() {
    let deviceId = "00008130-001C195E0E91802E"
    #expect(PublicIdentifier.canonicalized(deviceId) == deviceId)
}

/// The GUI mints this for a tab whose terminal never came up. It embeds a UUID
/// without being one, so it passes through whole.
@Test
func passesThroughAFailedTabPlaceholder() {
    let placeholder = "failed-550e8400-e29b-41d4-a716-446655440000"
    #expect(PublicIdentifier.canonicalized(placeholder) == placeholder)
}

@Test("passes through anything that is not a UUID", arguments: [
    "",
    "U",
    "current",
    "term01",
    "not-a-uuid",
    "550e8400-e29b-41d4-a716"
])
func passesThroughNonIdentifiers(raw: String) {
    #expect(PublicIdentifier.canonicalized(raw) == raw)
}

/// A ref pasted with surrounding whitespace still canonicalizes. Returning it
/// untouched would hand a caller a string that compares unequal to the same
/// identifier typed cleanly.
@Test("trims before parsing", arguments: [
    " 550E8400-E29B-41D4-A716-446655440000",
    "550E8400-E29B-41D4-A716-446655440000\n",
    "\t550E8400-E29B-41D4-A716-446655440000  "
])
func trimsSurroundingWhitespace(raw: String) {
    #expect(PublicIdentifier.canonicalized(raw) == "550e8400-e29b-41d4-a716-446655440000")
}
