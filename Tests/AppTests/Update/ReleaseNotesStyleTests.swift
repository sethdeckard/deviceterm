// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import SwiftUI
import Testing

/// Pin the spacing rhythm and the code-run font application the
/// update popover uses for parsed release notes. The absolute spacing
/// values matter less than their ordering, so the relationship checks
/// carry more weight here than the table itself.
struct ReleaseNotesStyleTests {
    private let codeFont = Font.system(.subheadline, design: .monospaced)

    /// The paragraph a fragment parses to, so the code-run tests exercise
    /// the same producer the popover reads from.
    private func paragraph(_ html: String) throws -> AttributedString {
        let block = try #require(ReleaseNotesDocument.parse(html).first)
        guard case let .paragraph(text) = block else {
            Issue.record("expected a paragraph, got \(block)")
            return AttributedString()
        }
        return text
    }

    @Test("the first block never takes a leading gap", arguments: [
        ReleaseNotesBlock.title("A"),
        .heading("A"),
        .paragraph("A"),
        .bullet("A")
    ])
    func firstBlockHasNoTopSpacing(block: ReleaseNotesBlock) {
        #expect(ReleaseNotesStyle.topSpacing(after: nil, before: block) == 0)
    }

    @Test("pairwise spacing table", arguments: [
        (ReleaseNotesBlock.paragraph("A"), ReleaseNotesBlock.heading("B"), CGFloat(18)),
        (.bullet("A"), .heading("B"), 18),
        (.title("A"), .heading("B"), 18),
        (.paragraph("A"), .title("B"), 14),
        (.bullet("A"), .title("B"), 14),
        (.title("A"), .paragraph("B"), 6),
        (.title("A"), .bullet("B"), 6),
        (.heading("A"), .paragraph("B"), 6),
        (.heading("A"), .bullet("B"), 6),
        (.bullet("A"), .bullet("B"), 4),
        (.bullet("A"), .paragraph("B"), 12),
        (.paragraph("A"), .bullet("B"), 8),
        (.paragraph("A"), .paragraph("B"), 10)
    ])
    func mapsBlockPairsToSpacing(
        previous: ReleaseNotesBlock,
        block: ReleaseNotesBlock,
        expected: CGFloat
    ) {
        #expect(ReleaseNotesStyle.topSpacing(after: previous, before: block) == expected)
    }

    /// A list stops reading as one run the moment the gap inside it rivals
    /// the gap that opens a section, which is the defect the table exists
    /// to prevent.
    @Test
    func sectionBreaksOutweighGapsInsideAList() {
        let insideList = ReleaseNotesStyle.topSpacing(after: .bullet("A"), before: .bullet("B"))
        let sectionBreak = ReleaseNotesStyle.topSpacing(after: .bullet("A"), before: .heading("B"))
        #expect(sectionBreak > insideList)
    }

    /// A heading belongs to what follows it, not to what it interrupts.
    @Test
    func headingsBindDownToTheirSection() {
        let above = ReleaseNotesStyle.topSpacing(after: .paragraph("A"), before: .heading("B"))
        let below = ReleaseNotesStyle.topSpacing(after: .heading("A"), before: .paragraph("B"))
        #expect(above > below)
    }

    @Test
    func codeFontLandsOnCodeRunsOnly() throws {
        let text = try paragraph("<p>Normalize a frame from <code>ax tree</code> first.</p>")
        let styled = ReleaseNotesStyle.applyingCodeFont(text, codeFont)

        for run in styled.runs {
            let isCode = run.inlinePresentationIntent?.contains(.code) == true
            #expect(run.font == (isCode ? codeFont : nil))
        }
    }

    @Test
    func codeFontPreservesTheText() throws {
        let text = try paragraph("<p>Normalize a frame from <code>ax tree</code> first.</p>")
        let styled = ReleaseNotesStyle.applyingCodeFont(text, codeFont)
        #expect(String(styled.characters) == String(text.characters))
    }

    /// A `<b><code>` span is one run carrying both intents. Assigning the
    /// code font must not cost it the bold, or the span renders monospaced
    /// and plain.
    @Test
    func codeFontKeepsBoldOnANestedCodeRun() throws {
        let text = try paragraph("<p>Then <b><code>ax sweep</code></b> runs.</p>")
        let styled = ReleaseNotesStyle.applyingCodeFont(text, codeFont)

        let nested = styled.runs.filter { run in
            run.inlinePresentationIntent?.contains(.code) == true
                && run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        #expect(nested.count == 1)
        #expect(nested.first?.font == codeFont)
    }

    /// Bold outside a code span keeps no font of its own, so the view's
    /// `.font(_:)` still governs it.
    @Test
    func codeFontLeavesSeparateBoldRunsAlone() throws {
        let text = try paragraph("<p><b>Retry</b> then <code>ax point</code>.</p>")
        let styled = ReleaseNotesStyle.applyingCodeFont(text, codeFont)

        let bolded = styled.runs.filter {
            $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                && $0.inlinePresentationIntent?.contains(.code) != true
        }
        #expect(!bolded.isEmpty)
        #expect(bolded.allSatisfy { $0.font == nil })
    }

    /// The debug fixture is the only thing the manual pass looks at, so a
    /// gap it never produces is a gap nobody judges.
    @MainActor
    @Test
    func theDebugFixtureProducesTheGapsWorthJudging() {
        let blocks = ReleaseNotesDocument.parse(UpdateSimulator.sampleNotes)
        let gaps = Set(blocks.enumerated().map { offset, block in
            ReleaseNotesStyle.topSpacing(
                after: offset == 0 ? nil : blocks[offset - 1],
                before: block
            )
        })

        // A section break, adjacent bullets, both paragraph/list
        // directions, and adjacent paragraphs.
        #expect(gaps.isSuperset(of: [18, 4, 8, 12, 10]))
    }

    @Test
    func codeFontIsIdentityWithoutCodeRuns() throws {
        let text = try paragraph("<p>No code spans here at all.</p>")
        #expect(ReleaseNotesStyle.applyingCodeFont(text, codeFont) == text)
    }
}
