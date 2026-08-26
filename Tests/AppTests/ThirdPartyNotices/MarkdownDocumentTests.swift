// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

/// MarkdownDocument parser: structural assertions on the tiny grammar
/// the bundled THIRD_PARTY_NOTICES.md is authored in.
struct MarkdownDocumentTests {
    @Test
    func parsesTitleHeadingParagraphAndVerbatim() {
        let sample = """
        # Title

        Intro **bold** line.

        ## Section

        ```
        VERBATIM line 1
        VERBATIM line 2
        ```
        """
        #expect(MarkdownDocument.parse(sample) == [
            .title("Title"),
            .paragraph("Intro **bold** line."),
            .heading("Section"),
            .verbatim("VERBATIM line 1\nVERBATIM line 2")
        ])
    }

    @Test
    func mergesConsecutiveParagraphLinesAndSplitsOnBlank() {
        #expect(MarkdownDocument.parse("line one\nline two\n\nnext") == [
            .paragraph("line one\nline two"),
            .paragraph("next")
        ])
    }

    @Test
    func toleratesUnterminatedFence() {
        #expect(MarkdownDocument.parse("```\nstuff") == [.verbatim("stuff")])
    }
}
