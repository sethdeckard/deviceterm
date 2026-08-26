// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Foundation
import Testing

/// Pin the HTML subset the update popover
/// renders. The parser reads notes written by hand for each release and
/// arriving over the network, so the malformed and unknown-markup cases
/// matter as much as the happy path. Unknown presentation tags lose their
/// formatting but keep their text; styles, scripts, declarations, and
/// comments are dropped outright.
struct ReleaseNotesDocumentTests {
    /// The block's text, with inline attributes dropped.
    private func text(_ block: ReleaseNotesBlock) -> String {
        switch block {
        case let .title(value), let .heading(value), let .paragraph(value), let .bullet(value):
            return String(value.characters)
        }
    }

    private func texts(_ blocks: [ReleaseNotesBlock]) -> [String] {
        blocks.map { text($0) }
    }

    private func isTitle(_ block: ReleaseNotesBlock) -> Bool {
        if case .title = block { return true }
        return false
    }

    private func isBullet(_ block: ReleaseNotesBlock) -> Bool {
        if case .bullet = block { return true }
        return false
    }

    @Test("heading levels split into title and heading", arguments: [
        ("<h1>A</h1>", true),
        ("<h2>A</h2>", true),
        ("<h3>A</h3>", false),
        ("<h4>A</h4>", false),
        ("<h5>A</h5>", false),
        ("<h6>A</h6>", false)
    ])
    func mapsHeadingLevels(html: String, isTitle: Bool) {
        let blocks = ReleaseNotesDocument.parse(html)
        #expect(blocks.count == 1)
        #expect(blocks.first == (isTitle ? .title("A") : .heading("A")))
    }

    @Test
    func collapsesWhitespaceAcrossIndentedSourceLines() {
        let blocks = ReleaseNotesDocument.parse("""
            <p>
              One sentence   wrapped
              across lines.
            </p>
            """)
        #expect(texts(blocks) == ["One sentence wrapped across lines."])
    }

    @Test
    func listItemsBecomeBulletsAndContainersVanish() {
        let blocks = ReleaseNotesDocument.parse("<ul><li>First</li><li>Second</li></ul>")
        #expect(blocks == [.bullet("First"), .bullet("Second")])
    }

    @Test
    func orderedListsAlsoBecomeBullets() {
        #expect(ReleaseNotesDocument.parse("<ol><li>Only</li></ol>") == [.bullet("Only")])
    }

    @Test
    func strongEmphasisAndCodeSurviveAsInlineIntents() throws {
        let blocks = ReleaseNotesDocument.parse(
            "<p>A <b>bold</b> and <em>soft</em> and <code>code</code> run.</p>"
        )
        let block = try #require(blocks.first)
        guard case let .paragraph(value) = block else {
            Issue.record("expected a paragraph, got \(block)")
            return
        }
        #expect(String(value.characters) == "A bold and soft and code run.")
        var seen: [String: InlinePresentationIntent] = [:]
        for run in value.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            seen[String(value[run.range].characters)] = intent
        }
        #expect(seen["bold"] == .stronglyEmphasized)
        #expect(seen["soft"] == .emphasized)
        #expect(seen["code"] == .code)
    }

    @Test
    func strongAliasesAgree() throws {
        let blocks = ReleaseNotesDocument.parse("<p><strong>x</strong> <i>y</i></p>")
        let block = try #require(blocks.first)
        guard case let .paragraph(value) = block else {
            Issue.record("expected a paragraph, got \(block)")
            return
        }
        let intents = value.runs.compactMap(\.inlinePresentationIntent)
        #expect(intents.contains(.stronglyEmphasized))
        #expect(intents.contains(.emphasized))
    }

    @Test
    func anchorsCarryTheirLink() throws {
        let blocks = ReleaseNotesDocument.parse(#"<p>See <a href="https://example.com/a">docs</a>.</p>"#)
        let block = try #require(blocks.first)
        guard case let .paragraph(value) = block else {
            Issue.record("expected a paragraph, got \(block)")
            return
        }
        #expect(String(value.characters) == "See docs.")
        let links = value.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://example.com/a")])
    }

    @Test("href is read as an attribute name, not a substring", arguments: [
        // A neighbouring attribute whose name merely contains or extends
        // "href" must not stand in for the real one.
        #"<a data-href="https://wrong.example" href="https://right.example">x</a>"#,
        #"<a hreflang="en" href="https://right.example">x</a>"#,
        #"<a href="https://right.example" data-href="https://wrong.example">x</a>"#,
        #"<a HREF="https://right.example">x</a>"#,
        // An unquoted value is still read as the attribute's value.
        "<a href=https://right.example >x</a>"
    ])
    func readsHrefAsAnAttributeName(html: String) throws {
        let block = try #require(ReleaseNotesDocument.parse(html).first)
        guard case let .paragraph(value) = block else {
            Issue.record("expected a paragraph, got \(block)")
            return
        }
        #expect(value.runs.compactMap(\.link) == [URL(string: "https://right.example")])
    }

    @Test
    func bareHrefEndingInASlashKeepsItsLink() throws {
        // The trailing slash belongs to the URL; treating it as a
        // self-closing tag would drop the anchor entirely.
        let block = try #require(ReleaseNotesDocument.parse("<a href=https://example.com/ >docs</a>").first)
        guard case let .paragraph(value) = block else {
            Issue.record("expected a paragraph, got \(block)")
            return
        }
        #expect(String(value.characters) == "docs")
        #expect(value.runs.compactMap(\.link) == [URL(string: "https://example.com/")])
    }

    @Test
    func entitiesInAttributeValuesDecode() throws {
        let block = try #require(
            ReleaseNotesDocument.parse(#"<p><a href="https://e.com/?a=1&amp;b=2">x</a></p>"#).first
        )
        guard case let .paragraph(value) = block else {
            Issue.record("expected a paragraph, got \(block)")
            return
        }
        #expect(value.runs.compactMap(\.link) == [URL(string: "https://e.com/?a=1&b=2")])
    }

    @Test
    func selfClosingInlineTagNeverOpensAStyle() {
        // <b/> opens nothing, so the text after it stays unstyled.
        let blocks = ReleaseNotesDocument.parse("<p><b/>plain</p>")
        #expect(texts(blocks) == ["plain"])
        guard case let .paragraph(value) = blocks[0] else { return }
        #expect(value.runs.allSatisfy { $0.inlinePresentationIntent == nil })
    }

    @Test
    func styleAndScriptAreDroppedWithTheirContent() {
        // A release-note fragment may carry a stylesheet; its CSS must never
        // surface as popover text.
        let blocks = ReleaseNotesDocument.parse("""
            <style>
              body { font: -apple-system-body; color: red; }
            </style>
            <script>var x = 1;</script>
            <p>Real text.</p>
            """)
        #expect(texts(blocks) == ["Real text."])
    }

    @Test
    func unterminatedStyleSwallowsTheRestRatherThanLeaking() {
        let blocks = ReleaseNotesDocument.parse("<p>Kept.</p><style>body { color: red; }")
        #expect(texts(blocks) == ["Kept."])
    }

    @Test
    func commentsAreDropped() {
        let blocks = ReleaseNotesDocument.parse("<p>Before<!-- hidden note -->After</p>")
        #expect(texts(blocks) == ["BeforeAfter"])
    }

    @Test("entities decode", arguments: [
        ("<p>a &amp; b</p>", "a & b"),
        ("<p>&lt;tag&gt;</p>", "<tag>"),
        ("<p>&quot;quoted&quot;</p>", "\"quoted\""),
        ("<p>it&apos;s</p>", "it's"),
        ("<p>it&#39;s</p>", "it's"),
        ("<p>don&#8217;t</p>", "don\u{2019}t"),
        ("<p>&#x2019;</p>", "\u{2019}"),
        ("<p>a&nbsp;b</p>", "a b")
    ])
    func decodesEntities(html: String, expected: String) {
        #expect(texts(ReleaseNotesDocument.parse(html)) == [expected])
    }

    @Test
    func unknownEntityIsLeftAsWritten() {
        #expect(texts(ReleaseNotesDocument.parse("<p>a &notreal; b</p>")) == ["a &notreal; b"])
    }

    @Test
    func unclosedBlockTagKeepsItsText() {
        let blocks = ReleaseNotesDocument.parse("<h3>Heading with no close")
        #expect(blocks == [.heading("Heading with no close")])
    }

    @Test
    func unknownTagsLoseFormattingButNotContent() {
        let blocks = ReleaseNotesDocument.parse("<p>A <span class=\"x\">kept</span> word.</p>")
        #expect(texts(blocks) == ["A kept word."])
    }

    @Test
    func bareTextWithNoTagsBecomesOneParagraph() {
        #expect(ReleaseNotesDocument.parse("Just a sentence.") == [.paragraph("Just a sentence.")])
    }

    @Test
    func strayAngleBracketIsTreatedAsText() {
        #expect(texts(ReleaseNotesDocument.parse("<p>a < b</p>")) == ["a < b"])
    }

    @Test
    func lineBreakSplitsWithinABlock() {
        #expect(texts(ReleaseNotesDocument.parse("<p>One<br/>Two</p>")) == ["One\nTwo"])
    }

    @Test
    func leadingLineBreakIsNotEmitted() {
        // A <br> before any text would otherwise open the block with a
        // blank line the author never wrote.
        #expect(texts(ReleaseNotesDocument.parse("<p><br>One</p>")) == ["One"])
    }

    @Test("text-free input yields no blocks", arguments: [
        "",
        "   \n\t ",
        "<style>body { color: red; }</style>",
        "<p></p><ul></ul>",
        "<!-- only a comment -->"
    ])
    func yieldsNoBlocksForTextFreeInput(html: String) {
        #expect(ReleaseNotesDocument.parse(html).isEmpty)
    }

    @Test
    func doctypeIsIgnored() {
        // The authoring contract forbids one, but a stray declaration must
        // not swallow the notes.
        #expect(texts(ReleaseNotesDocument.parse("<!DOCTYPE html><p>Text.</p>")) == ["Text."])
    }

    @Test
    func unmatchedInlineCloseIsIgnoredAndStopsAtTheBlock() throws {
        // The stray </i> matches nothing, so <b> stays open to the end of
        // its own block. The next block has to start clean.
        let blocks = ReleaseNotesDocument.parse("<p><b>bold</i> still bold</p><p>plain</p>")
        #expect(blocks.count == 2)
        guard case let .paragraph(first) = try #require(blocks.first),
            case let .paragraph(second) = try #require(blocks.last) else {
            Issue.record("expected two paragraphs, got \(blocks)")
            return
        }
        #expect(String(first.characters) == "bold still bold")
        #expect(first.runs.allSatisfy { $0.inlinePresentationIntent == .stronglyEmphasized })
        #expect(String(second.characters) == "plain")
        #expect(second.runs.allSatisfy { $0.inlinePresentationIntent == nil })
    }

    @Test
    func unclosedInlineDoesNotBleedIntoTheNextBullet() throws {
        let blocks = ReleaseNotesDocument.parse("<ul><li><b>bold</li><li>plain</li></ul>")
        #expect(blocks.count == 2)
        guard case let .bullet(second) = try #require(blocks.last) else {
            Issue.record("expected a bullet, got \(blocks)")
            return
        }
        #expect(String(second.characters) == "plain")
        #expect(second.runs.allSatisfy { $0.inlinePresentationIntent == nil })
    }

    @Test
    func parsesTheShippedReleaseNotes() throws {
        // The exact HTML published for 0.4.0, stylesheet and all.
        let url = try #require(
            Bundle.module.url(forResource: "release-notes-sample", withExtension: "html")
        )
        let blocks = ReleaseNotesDocument.parse(try String(contentsOf: url, encoding: .utf8))

        var titles: [String] = []
        var headings: [String] = []
        var paragraphs = 0
        var bullets = 0
        for block in blocks {
            switch block {
            case let .title(value):
                titles.append(String(value.characters))

            case let .heading(value):
                headings.append(String(value.characters))

            case .paragraph:
                paragraphs += 1

            case .bullet:
                bullets += 1
            }
        }

        #expect(titles == ["DeviceTerm 0.4.0"])
        #expect(headings == [
            "Automation And Protection",
            "Tabs And Device Panes",
            "Reliability",
            "Updating From 0.3.0",
            "Known Limits"
        ])
        #expect(paragraphs == 2)
        #expect(bullets == 16)

        // The first block is the title, and the stylesheet never lands as
        // text anywhere in the document.
        #expect(blocks.first == .title("DeviceTerm 0.4.0"))
        let everything = texts(blocks).joined(separator: "\n")
        #expect(!everything.contains("-apple-system"))
        #expect(!everything.contains("margin-bottom"))
        #expect(!everything.contains("{"))

        // Bullets keep their inline markup rather than flattening.
        let firstBullet = try #require(blocks.first(where: isBullet))
        guard case let .bullet(value) = firstBullet else {
            Issue.record("expected a bullet, got \(firstBullet)")
            return
        }
        #expect(String(value.characters).hasPrefix("Open Automation Tab replaces Open Orchestrator Tab."))
        #expect(value.runs.compactMap(\.inlinePresentationIntent).contains(.stronglyEmphasized))
    }

    @MainActor
    @Test
    func simulatorNotesRenderAsBlocks() {
        // The debug fixture drives the real popover, so it has to parse.
        let blocks = ReleaseNotesDocument.parse(UpdateSimulator.sampleNotes)
        #expect(blocks.contains(where: isTitle))
        #expect(blocks.filter(isBullet).count == 5)
        #expect(!texts(blocks).joined().contains("-apple-system"))
    }
}
