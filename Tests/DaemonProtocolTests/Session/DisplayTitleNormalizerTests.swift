// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

// A display title is written by whatever program runs in the tab and is
// then republished to every `tabs.list` reader, so the normalizer is a
// security boundary, not a formatting nicety: it has to strip the
// scalars that let one tab impersonate another, bound the value, and cut
// only on grapheme boundaries so a hostile title can't be truncated into
// invalid UTF-8.

@Test
func keepsAnOrdinaryTitleVerbatim() {
    #expect(DisplayTitleNormalizer.normalize("vim Sources/App/Router.swift")
        == "vim Sources/App/Router.swift")
}

@Test
func normalizesNilAndBlankToNil() {
    #expect(DisplayTitleNormalizer.normalize(nil) == nil)
    #expect(DisplayTitleNormalizer.normalize("") == nil)
    #expect(DisplayTitleNormalizer.normalize("   \t  ") == nil)
}

@Test
func stripsControlScalars() {
    // C0 (bell, newline, tab), DEL, and C1 all go: a label that carries
    // them breaks any line-oriented consumer of `tabs list`.
    #expect(DisplayTitleNormalizer.normalize("vim\u{07} foo\nbar\u{7F}\u{85}")
        == "vim foobar")
}

@Test
func stripsBidiControlsButKeepsJoiners() {
    // Bidi overrides/isolates/marks can visually reorder a label so one
    // tab impersonates another's activity string. `U+200D` ZWJ is NOT in
    // that set: it is load-bearing inside legitimate emoji clusters.
    let hostile = "safe\u{202E}elifedoc\u{202C}\u{2066}x\u{2069}\u{200F}\u{061C}"
    #expect(DisplayTitleNormalizer.normalize(hostile) == "safeelifedocx")

    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
    #expect(DisplayTitleNormalizer.normalize("home \(family)") == "home \(family)")
}

@Test(
    "invisible scalars a whitespace trim would miss",
    arguments: [
        "\u{FEFF}",     // BOM / ZWNBSP
        "\u{00AD}",     // soft hyphen
        "\u{180E}",     // Mongolian vowel separator
        "\u{200B}",     // zero width space
        "\u{2060}",     // word joiner
        "\u{2062}",     // invisible times
        "\u{3164}",     // Hangul filler: an `otherLetter` that renders as nothing
        "\u{E0067}",    // tag letter: the invisible-text smuggling channel
        "\u{034F}"      // combining grapheme joiner
    ]
)
func stripsInvisibleScalarsAWhitespaceTrimWouldMiss(scalar: String) {
    // These are `Default_Ignorable_Code_Point`s, not `Z*`, so
    // `trimmingCharacters(in: .whitespacesAndNewlines)` leaves them. Kept,
    // they would produce a non-nil title that renders BLANK, blanking the
    // label instead of falling back to the session name. Enumerating them
    // by hand is what let `U+2060` through; the property is the policy.
    // The joiners and variation selectors are the deliberate exception,
    // pinned separately below.
    #expect(DisplayTitleNormalizer.normalize(scalar) == nil)
    #expect(DisplayTitleNormalizer.normalize("a\(scalar)b") == "ab")
}

@Test
func keepsTheIgnorableScalarsThatAreLoadBearingInsideACluster() {
    // ZWNJ is orthographically load-bearing in Persian and several Indic
    // scripts, and the variation selectors pick emoji presentation and CJK
    // ideographic variants. All three are ignorable but not invisibility
    // tricks, so they survive *within* a visible title.
    #expect(DisplayTitleNormalizer.normalize("a\u{200C}b") == "a\u{200C}b")
    #expect(DisplayTitleNormalizer.normalize("\u{2764}\u{FE0F} x") == "\u{2764}\u{FE0F} x")

    // The accepted consequence: `"a\u{200D}"` stays distinct from `"a"`
    // though the two render alike. Titles are descriptive, not identifying;
    // `shortId` resolves the tab. Corrupting legitimate Persian, Indic, and
    // emoji titles to close that visual gap would be the worse trade.

    // On their own they render as nothing, so they are not content: a
    // title made only of them is nil, not a blank-looking label.
    #expect(DisplayTitleNormalizer.normalize("\u{200D}") == nil)
    #expect(DisplayTitleNormalizer.normalize("\u{200C}\u{FE0F}") == nil)
}

@Test
func treatsTheBrailleBlankAsSpaceRatherThanContent() {
    // `U+2800` renders as nothing, being the braille block's space, a
    // pattern with no raised dots. Yet it is neither whitespace nor
    // default-ignorable (its category is `Symbol, other`), so every
    // property-based filter misses it and a title made of it would be a
    // non-nil label that renders blank.
    #expect(DisplayTitleNormalizer.normalize("\u{2800}\u{2800}") == nil)
    #expect(DisplayTitleNormalizer.normalize("\u{2800} vim \u{2800}") == "vim")

    // Stripping it outright would be wrong: between braille characters it
    // IS the word separator, so running the words together would corrupt a
    // legitimate title.
    #expect(DisplayTitleNormalizer.normalize("\u{2803}\u{2800}\u{2805}")
        == "\u{2803}\u{2800}\u{2805}")
}

@Test
func composesToNFC() throws {
    let decomposed = "e\u{0301}"                       // e + combining acute
    let normalized = try #require(DisplayTitleNormalizer.normalize(decomposed))
    #expect(normalized == "é")
    #expect(normalized.unicodeScalars.count == 1)
}

@Test
func truncatesOnAGraphemeBoundary() throws {
    // Each of these is 4 UTF-8 bytes, so exactly `byteBudget / 4` fit and
    // the cut lands between clusters, never inside one.
    let wide = String(repeating: "😀", count: 200)
    let normalized = try #require(DisplayTitleNormalizer.normalize(wide))
    #expect(normalized.count == DisplayTitleNormalizer.byteBudget / 4)
    #expect(normalized.utf8.count == DisplayTitleNormalizer.byteBudget)
}

@Test
func dropsAWholeClusterRatherThanSplittingIt() throws {
    // Fill the budget to one byte short of a 4-byte cluster: the cluster
    // is dropped whole, so the result is shorter than the budget rather
    // than ending in a half-encoded scalar.
    let head = String(repeating: "a", count: DisplayTitleNormalizer.byteBudget - 3)
    let normalized = try #require(DisplayTitleNormalizer.normalize(head + "😀" + "😀"))
    #expect(normalized == head)
    #expect(normalized.utf8.count == DisplayTitleNormalizer.byteBudget - 3)
}

@Test
func boundsTheWorkOnAHugeTitleWithoutLosingTheKeptPrefix() throws {
    // The scan limit is a work bound on main-actor-normalized, fully
    // caller-controlled text. It must not change what a title of
    // ordinary shape keeps.
    let huge = String(repeating: "a", count: 1_000_000)
    let normalized = try #require(DisplayTitleNormalizer.normalize(huge))
    #expect(normalized == String(repeating: "a", count: DisplayTitleNormalizer.byteBudget))
}

@Test
func normalizesAnAllProhibitedTitleToNil() {
    // Non-empty in, nothing survives: the caller must transmit this as a
    // CLEAR, not skip it, or a previously cached title outlives the value
    // that replaced it.
    #expect(DisplayTitleNormalizer.normalize("\u{202A}\u{202C}\u{200E}\u{001B}") == nil)
}

@Test
func normalizesASingleOversizedGraphemeToNil() {
    // One cluster already over budget can't be truncated without
    // splitting it, so nothing is kept.
    let huge = "a" + String(repeating: "\u{0301}", count: 300)
    #expect(huge.count == 1)
    #expect(DisplayTitleNormalizer.normalize(huge) == nil)
}
