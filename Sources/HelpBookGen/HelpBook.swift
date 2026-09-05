// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Markdown

/// Turns one markdown guide into the page set of a help book.
///
/// Pure: it returns files as strings rather than writing them, so the
/// whole conversion is testable without a filesystem. `main.swift` does
/// the writing and `scripts/make-help-book.sh` builds the index around
/// the result.
struct HelpBook {
    /// One output file, named relative to the book's `.lproj` directory.
    struct File {
        let name: String
        let contents: String
    }

    let title: String
    let topics: [Topic]
    let files: [File]

    /// Convert `markdown` into a book titled `title`.
    ///
    /// The anchor map is built across every topic before any page
    /// renders, because a link in the first topic routinely points at a
    /// heading in the last. Rendering page by page without that first
    /// pass is how a cross-reference silently turns into a dead `#slug`.
    init(markdown: String, title: String) {
        let document = Document(parsing: markdown)
        let topics = TopicSplitter.split(document)

        var anchors: [String: LinkRewriter.Anchor] = [:]
        for topic in topics {
            anchors[topic.slug] = .init(page: topic.fileName, isPageTitle: true)
            for heading in topic.body.flatMap(\.headings) {
                let slug = Slug.make(heading.plainText)
                // Page titles override a matching subheading, so a link
                // prefers the page. Among body headings, first wins.
                if anchors[slug] == nil {
                    anchors[slug] = .init(page: topic.fileName, isPageTitle: false)
                }
            }
        }

        let links = LinkRewriter(anchors: anchors)
        var files = topics.map { topic in
            File(
                name: topic.fileName,
                contents: PageTemplate.page(
                    title: topic.title,
                    body: HTMLRenderer.render(topic.body, links: links)
                )
            )
        }
        files.append(File(name: "index.html", contents: Self.index(title: title, topics: topics)))
        files.append(File(name: "style.css", contents: PageTemplate.styleSheet))

        self.title = title
        self.topics = topics
        self.files = files
    }

    /// The book's landing page: the topic list, in the guide's own order.
    /// This is what `HPDBookAccessPath` points at and what Help Viewer
    /// opens for "DeviceTerm Help".
    private static func index(title: String, topics: [Topic]) -> String {
        var body = "<ul>\n"
        for topic in topics {
            let href = HTMLRenderer.escape(topic.fileName)
            let name = HTMLRenderer.escape(topic.title)
            body += "<li><a href=\"\(href)\">\(name)</a></li>\n"
        }
        body += "</ul>\n"
        body += """
            <p>The full guide, along with the automation and integration
            references, is at <a href="\(LinkRewriter.docsBase)">\(LinkRewriter.docsBase)</a>.</p>

            """
        return PageTemplate.page(title: title, body: body)
    }
}

private extension Markup {
    /// Every heading at or below this node, itself included. Used to map
    /// `###` anchors to the page that ends up carrying them.
    var headings: [Heading] {
        var found: [Heading] = []
        if let heading = self as? Heading {
            found.append(heading)
        }
        for child in children {
            found.append(contentsOf: child.headings)
        }
        return found
    }
}
