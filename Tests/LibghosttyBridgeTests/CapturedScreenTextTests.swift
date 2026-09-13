// SPDX-License-Identifier: GPL-3.0-or-later

@testable import LibghosttyBridge
import Testing

// The engine ends styled rows with CRLF and plain rows with LF. A
// capture settles on LF for both so the two formats can be compared
// row for row, and so a consumer joining rows sees one convention.

@Test(
    "CRLF row separators normalize to LF",
    arguments: [
        ("a\r\nb\r\n", "a\nb\n"),
        ("a\nb\n", "a\nb\n"),
        ("", ""),
        ("no trailing separator", "no trailing separator")
    ]
)
func normalizesRowSeparators(input: String, expected: String) {
    #expect(CapturedScreenText.normalizingRowSeparators(input) == expected)
}

@Test
func preservesEscapeSequencesAroundSeparators() {
    let styled = "\u{1b}[31mred\u{1b}[0m\r\n\u{1b}[32mgreen\u{1b}[0m\r\n"

    #expect(
        CapturedScreenText.normalizingRowSeparators(styled)
            == "\u{1b}[31mred\u{1b}[0m\n\u{1b}[32mgreen\u{1b}[0m\n"
    )
}

@Test
func leavesALoneCarriageReturnAlone() {
    // A bare CR is content the terminal emitted, not a row separator.
    #expect(CapturedScreenText.normalizingRowSeparators("a\rb") == "a\rb")
}
