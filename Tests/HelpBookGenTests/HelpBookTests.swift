// SPDX-License-Identifier: GPL-3.0-or-later

@testable import HelpBookGen
import Testing

/// The conversion from the markdown guide to help pages.
///
/// The failures worth catching here are the silent ones. A dropped table
/// or a cross-reference pointing at a page that doesn't exist passes the
/// build and surfaces only when a reader opens the page.
struct HelpBookTests {
    private static func book(_ markdown: String) -> HelpBook {
        HelpBook(markdown: markdown, title: "DeviceTerm Help")
    }

    private static func page(_ book: HelpBook, _ name: String) -> String {
        book.files.first { $0.name == name }?.contents ?? ""
    }

    @Test
    func splitsAtLevelTwoHeadings() {
        let book = Self.book("""
            # Guide

            Intro prose.

            ## First Topic

            One.

            ## Second Topic

            Two.
            """)
        #expect(book.topics.map(\.title) == ["First Topic", "Second Topic"])
        #expect(book.topics.map(\.fileName) == ["first-topic.html", "second-topic.html"])
    }

    @Test
    func frontMatterIsNotATopic() {
        // Only level-two sections become topics, so the `#` title and
        // the lead paragraphs that precede the first one are omitted.
        let book = Self.book("""
            # Guide

            Intro prose.

            ## Only Topic

            Body.
            """)
        #expect(book.topics.count == 1)
        #expect(!Self.page(book, "only-topic.html").contains("Intro prose"))
    }

    @Test
    func aHeadingWithNoBodyStillBecomesAPage() {
        // Dropping it would lose a heading the guide's own contents list
        // still links to, and the dead link would point at nothing.
        let book = Self.book("""
            ## Empty

            ## Full

            Body.
            """)
        #expect(book.topics.map(\.title) == ["Empty", "Full"])
    }

    @Test
    func theGuidesOwnContentsListIsNotAPage() {
        // The book's index is that list. Shipping both hands Help Viewer
        // two tables of contents to offer for the same search.
        let book = Self.book("""
            ## Contents

            - [Real Topic](#real-topic)

            ## Real Topic

            Body.
            """)
        #expect(book.topics.map(\.title) == ["Real Topic"])
        #expect(!book.files.contains { $0.name == "contents.html" })
    }

    @Test
    func tablesSurviveAsTables() {
        // Tables carry most of the guide's reference material. Rendered
        // through the default walk they would come out as a run of prose
        // with the structure gone.
        let book = Self.book("""
            ## Config

            | Key | Default |
            |---|---|
            | `auto-update` | `check` |
            """)
        let html = Self.page(book, "config.html")
        #expect(html.contains("<table>"))
        #expect(html.contains("<th>Key</th>"))
        #expect(html.contains("<code>auto-update</code>"))
        #expect(html.contains("<td><code>check</code></td>"))
    }

    @Test
    func fencedCodeSurvivesVerbatim() {
        let book = Self.book("""
            ## Boot

            ```sh
            xcrun simctl boot "iPhone 17 Pro"
            ```
            """)
        let html = Self.page(book, "boot.html")
        #expect(html.contains("<pre><code>"))
        #expect(html.contains("xcrun simctl boot"))
    }

    @Test
    func inDocumentAnchorResolvesToTheOwningPage() {
        // The link is written against a single-page render. After the
        // split its target lives elsewhere, so it has to become a file.
        let book = Self.book("""
            ## First

            See [the other one](#second-topic).

            ## Second Topic

            Body.
            """)
        #expect(Self.page(book, "first.html").contains("href=\"second-topic.html\""))
    }

    @Test
    func anchorToASubheadingKeepsItsFragment() {
        // A `###` is not a page of its own, so the link needs both the
        // page that carries it and the fragment within.
        let book = Self.book("""
            ## First

            See [the detail](#a-detail).

            ## Second

            ### A Detail

            Body.
            """)
        let html = Self.page(book, "first.html")
        #expect(html.contains("href=\"second.html#a-detail\""))
        #expect(Self.page(book, "second.html").contains("id=\"a-detail\""))
    }

    @Test
    func anUnmatchedAnchorIsLeftAlone() {
        // It was already broken in the source. Pointing it somewhere
        // plausible would hide that rather than fix it.
        let book = Self.book("""
            ## Only

            See [nowhere](#no-such-heading).
            """)
        #expect(Self.page(book, "only.html").contains("href=\"#no-such-heading\""))
    }

    @Test
    func siblingDocumentsGoToThePublishedCopy() {
        // AUTOMATION.md is not in the book, so an in-repo relative link
        // would resolve to nothing inside the bundle.
        let book = Self.book("""
            ## Only

            See [automation](AUTOMATION.md) and
            [the report](INTEGRATION.md#version-report).
            """)
        let html = Self.page(book, "only.html")
        #expect(html.contains("href=\"https://deviceterm.com/docs/automation/\""))
        #expect(html.contains("href=\"https://deviceterm.com/docs/integration/#version-report\""))
    }

    @Test
    func repositoryFilesGoToGitHub() {
        // These are not published on the site and are not in the book.
        // Left relative they would resolve against en.lproj, where no
        // part of the repository exists, so they'd be dead links.
        let book = Self.book("""
            ## Only

            See [the checklist](../Tests/Manual/watchos-checklist.md) and
            [as-tested](../Sources/CoreSimulatorBridge/as-tested.md).
            """)
        let html = Self.page(book, "only.html")
        let base = "https://github.com/sethdeckard/deviceterm/blob/main"
        #expect(html.contains("href=\"\(base)/Tests/Manual/watchos-checklist.md\""))
        #expect(html.contains("href=\"\(base)/Sources/CoreSimulatorBridge/as-tested.md\""))
    }

    @Test
    func noGeneratedLinkStaysRelative() {
        // The sweep the two cases above are instances of: after
        // rewriting, nothing in the book may point at a path that only
        // exists in a checkout.
        let book = Self.book("""
            ## Only

            [a](../Tests/Manual/x.md), [b](AUTOMATION.md), [c](#only),
            [d](https://example.com).
            """)
        let html = Self.page(book, "only.html")
        #expect(!html.contains("href=\"../"))
        #expect(!html.contains("href=\"docs/"))
    }

    @Test
    func aPathClimbingPastTheRepositoryRootIsLeftAlone() {
        // Nothing sensible to point it at, and guessing would invent a
        // URL that looks right and isn't.
        let book = Self.book("""
            ## Only

            See [outside](../../elsewhere/thing.md).
            """)
        #expect(Self.page(book, "only.html").contains("href=\"../../elsewhere/thing.md\""))
    }

    @Test
    func absoluteURLsPassThrough() {
        let book = Self.book("""
            ## Only

            See [the site](https://example.com/x).
            """)
        #expect(Self.page(book, "only.html").contains("href=\"https://example.com/x\""))
    }

    @Test
    func everyPageCarriesItsAppleTitle() {
        // Help Viewer takes a result's displayed title from this tag, not
        // from `<title>`. A page without one is indexed by filename.
        let book = Self.book("""
            ## Mirror a Physical Device

            Body.
            """)
        let html = Self.page(book, "mirror-a-physical-device.html")
        #expect(html.contains(#"<meta name="AppleTitle" content="Mirror a Physical Device">"#))
    }

    @Test
    func theBookShipsAnIndexAndAStylesheet() {
        let book = Self.book("""
            ## One

            Body.
            """)
        let names = Set(book.files.map(\.name))
        #expect(names.contains("index.html"))
        #expect(names.contains("style.css"))
        #expect(Self.page(book, "index.html").contains("href=\"one.html\""))
    }

    @Test
    func subheadingsShiftDownOneLevel() {
        // The template owns the `<h1>`, which is the topic title, so a
        // source `###` renders as `<h2>`.
        let book = Self.book("""
            ## Topic

            ### Sub

            Body.
            """)
        #expect(Self.page(book, "topic.html").contains("<h2 id=\"sub\">Sub</h2>"))
    }

    @Test
    func markupCharactersInProseAreEscaped() {
        let book = Self.book("""
            ## Only

            A < b & c "quoted".
            """)
        let html = Self.page(book, "only.html")
        #expect(html.contains("&lt;"))
        #expect(html.contains("&amp;"))
    }
}

/// The anchor rule the guide's hand-written links were authored against.
struct SlugTests {
    @Test("slugs match what the source links already assume", arguments: [
        ("Coexist With Device Hub", "coexist-with-device-hub"),
        // The period vanishes rather than becoming a hyphen, which is why
        // the existing link reads `#coexist-with-simulatorapp`.
        ("Coexist With Simulator.app", "coexist-with-simulatorapp"),
        ("Use DeviceTerm as a Terminal", "use-deviceterm-as-a-terminal"),
        ("Boot With xcrun simctl", "boot-with-xcrun-simctl")
    ])
    func slugsMatchGitHubAnchors(text: String, expected: String) {
        #expect(Slug.make(text) == expected)
    }
}
