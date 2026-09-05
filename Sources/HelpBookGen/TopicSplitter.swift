// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Markdown

/// Cuts a parsed guide into one `Topic` per `##` heading.
enum TopicSplitter {
    /// Sections that are navigation rather than content, and so have no
    /// page of their own. The guide opens with a `## Contents` list of
    /// its own headings; the book's generated index is that list, and
    /// shipping both gives Help Viewer two tables of contents to offer.
    static let navigationSlugs: Set<String> = ["contents"]
    /// Split `document` at its level-2 headings.
    ///
    /// Anything before the first `##` is front matter: the `#` title and
    /// the lead paragraphs. It is dropped rather than becoming a page,
    /// since only level-two sections are topics. The `## Contents` list
    /// is a level-two section and so arrives here like any other; it is
    /// removed separately, by `navigationSlugs`.
    ///
    /// A level-2 heading with no content under it still becomes a topic,
    /// as an empty page. Silently dropping it would lose a heading the
    /// guide's own contents list still points at.
    static func split(_ document: Document) -> [Topic] {
        var topics: [Topic] = []
        var title: String?
        var body: [Markup] = []

        func flush() {
            guard let title else { return }
            let slug = Slug.make(title)
            if !navigationSlugs.contains(slug) {
                topics.append(Topic(title: title, slug: slug, body: body))
            }
            body = []
        }

        for child in document.children {
            if let heading = child as? Heading, heading.level == 2 {
                flush()
                title = heading.plainText
            } else if title != nil {
                body.append(child)
            }
        }
        flush()
        return topics
    }
}
