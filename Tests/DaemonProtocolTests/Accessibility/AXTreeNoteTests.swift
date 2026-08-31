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
func sweepTruncationNotesAreStable() {
    #expect(
        AXTreeNote.sweepTruncated.rawValue ==
        // swiftlint:disable:next line_length
        "the sweep stopped at its time budget with part of the grid unqueried; 'sweepedPoints' counts what it reached, and 'deviceterm ax sweep --budget <ms>' buys a longer walk"
    )
    #expect(
        AXTreeNote.sweepTruncatedAtMaxBudget.rawValue ==
        // swiftlint:disable:next line_length
        "the sweep stopped at the largest budget the daemon allows with part of the grid unqueried; 'sweepedPoints' counts what it reached, so widen 'deviceterm ax sweep --step <0..1>' or retry when the pane is serving fewer accessibility reads"
    )
}

@Test(arguments: [
    (0, AXTreeNote.sweepTruncated),
    (AXSweepBudget.defaultMs, .sweepTruncated),
    (AXSweepBudget.maxMs - 1, .sweepTruncated),
    (AXSweepBudget.maxMs, .sweepTruncatedAtMaxBudget),
    (AXSweepBudget.maxMs * 10, .sweepTruncatedAtMaxBudget)
])
func aSweepAtTheCeilingIsNotToldToRaiseItsBudget(budgetMs: Int, expected: AXTreeNote) {
    // The ordinary note advises `--budget`, which is a dead end for a caller
    // already at the maximum: it can only coarsen its step or wait for the
    // pane's accessibility queue to quieten.
    #expect(AXTreeNote.forTruncatedSweep(budgetMs: budgetMs) == expected)
}

@Test
func onlyTheCeilingNoteAvoidsRecommendingTheBudgetFlag() {
    // What separates the two, stated as behavior rather than as identity: a
    // caller at the ceiling is pointed at a flag it can still move.
    #expect(AXTreeNote.sweepTruncated.rawValue.contains("--budget"))
    #expect(!AXTreeNote.sweepTruncatedAtMaxBudget.rawValue.contains("--budget"))
    #expect(AXTreeNote.sweepTruncatedAtMaxBudget.rawValue.contains("--step"))
}

@Test
func treeIncompleteRawValueIsStable() {
    // Pinned like the notes above, because the sentence reaches agents as the
    // literal at `tree["note"]`. Match by enum case or by `noteCode`, never by
    // string equality: this text can be reworded and the code cannot.
    #expect(
        AXTreeNote.treeIncomplete.rawValue ==
        // swiftlint:disable:next line_length
        "hit-testing found an element this tree does not contain, so the walk did not reach everything on screen; use 'deviceterm ax sweep' to grid-walk via objectAtPoint, or 'deviceterm ax point <x> <y>' for a single element"
    )
}

@Test
func theIncompletenessNoteReportsEvidenceRatherThanACause() {
    // The note is named and worded for what a hit-test proved, not for the
    // web view that motivated it. A caller reading a diagnosis of "web" into a
    // screen thin for some other reason is the failure this wording avoids.
    let note = AXTreeNote.treeIncomplete.rawValue
    #expect(note.contains("hit-testing"))
    #expect(!note.lowercased().contains("web"))
}

@Test
func everyNoteNamesACommandThatAdvancesTheCaller() {
    // A note exists to move someone forward, so each one names the verb that
    // does it. The house prose rules out em and en dashes, and
    // `IntegrationGuideTests` applies the same guard to `docs/INTEGRATION.md`.
    for note in AXTreeNote.allCases {
        #expect(note.rawValue.contains("deviceterm ax "))
        #expect(!note.rawValue.contains("\u{2014}"))
        #expect(!note.rawValue.contains("\u{2013}"))
    }
}

@Test
func everyNoteCarriesAUniqueStableCode() {
    let codes = AXTreeNote.allCases.map(\.code)
    #expect(codes.allSatisfy { !$0.isEmpty })
    #expect(Set(codes).count == AXTreeNote.allCases.count)
    // Pinned like the raw values above: the code is the identity a JSON
    // client branches on, so a change here is a deliberate wire change.
    #expect(AXTreeNote.watchOSEnumerationUnsupported.code == "ax.watchOSEnumerationUnsupported")
    #expect(AXTreeNote.treeIncomplete.code == "ax.treeIncomplete")
    #expect(AXTreeNote.sweepTruncated.code == "ax.sweepTruncated")
    #expect(AXTreeNote.sweepTruncatedAtMaxBudget.code == "ax.sweepTruncatedAtMaxBudget")
}

@Test
func everyCodeRoundTripsBackToItsNote() {
    for note in AXTreeNote.allCases {
        #expect(AXTreeNote(code: note.code) == note)
    }
    #expect(AXTreeNote(code: "ax.notANote") == nil)
    #expect(AXTreeNote(code: "") == nil)
    // The sentence is not a code, so the two initializers stay distinct.
    #expect(AXTreeNote(code: AXTreeNote.sweepTruncated.rawValue) == nil)
}

@Test
func theTwoTruncationNotesAreDistinguishableWithoutReadingProse() {
    // The reason `code` exists. Both are `wait.inconclusive` and both are
    // sentences, so without a token the only machine-readable difference
    // between them is a paragraph.
    #expect(AXTreeNote.sweepTruncated.code != AXTreeNote.sweepTruncatedAtMaxBudget.code)
}

@Test
func decodesFromRawString() throws {
    // Quote the raw value so JSONDecoder sees a JSON string literal.
    let raw = AXTreeNote.watchOSEnumerationUnsupported.rawValue
    let json = Data("\"\(raw)\"".utf8)
    let note = try JSONDecoder().decode(AXTreeNote.self, from: json)
    #expect(note == .watchOSEnumerationUnsupported)
}
