// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Markdown

/// Walks parsed markdown and emits the HTML body of one help page.
///
/// swift-markdown parses but ships no HTML emitter, so this is the part
/// the package dependency does not cover. It handles the constructs
/// `docs/USAGE.md` actually uses; anything else falls through
/// `defaultVisit`, which renders children and drops the wrapper rather
/// than throwing away the text inside it.
///
/// Headings shift down one level. The page template owns the `<h1>`,
/// which is the topic's `##` heading, so a `###` in the source becomes
/// `<h2>` here. Each keeps an `id` matching its source anchor, so a
/// cross-page link can still land on it.
struct HTMLRenderer: MarkupVisitor {
    let links: LinkRewriter

    /// Escapes the HTML-sensitive characters for use in text and in
    /// double-quoted attributes. Which of the five a given position
    /// needs differs; escaping all of them everywhere lets a caller stay
    /// independent of where its output lands.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&":
                out += "&amp;"

            case "<":
                out += "&lt;"

            case ">":
                out += "&gt;"

            case "\"":
                out += "&quot;"

            case "'":
                out += "&#39;"

            default:
                out.append(character)
            }
        }
        return out
    }

    /// Render a topic's blocks. A free function rather than `visit` on the
    /// document, because a topic is a slice of one.
    static func render(_ blocks: [Markup], links: LinkRewriter) -> String {
        var renderer = HTMLRenderer(links: links)
        return blocks.map { renderer.visit($0) }.joined()
    }

    mutating func defaultVisit(_ markup: Markup) -> String {
        let parts = markup.children.map { child in
            var copy = self
            return copy.visit(child)
        }
        return parts.joined()
    }

    mutating func visitText(_ text: Text) -> String {
        Self.escape(text.string)
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        "<p>\(defaultVisit(paragraph))</p>\n"
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        let level = min(heading.level - 1, 6)
        let id = Slug.make(heading.plainText)
        return "<h\(level) id=\"\(Self.escape(id))\">\(defaultVisit(heading))</h\(level)>\n"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        "<em>\(defaultVisit(emphasis))</em>"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>\(defaultVisit(strong))</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        "<del>\(defaultVisit(strikethrough))</del>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(Self.escape(inlineCode.code))</code>"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        "<pre><code>\(Self.escape(codeBlock.code))</code></pre>\n"
    }

    mutating func visitLink(_ link: Link) -> String {
        let destination = links.rewrite(link.destination ?? "")
        return "<a href=\"\(Self.escape(destination))\">\(defaultVisit(link))</a>"
    }

    mutating func visitImage(_ image: Image) -> String {
        let source = Self.escape(image.source ?? "")
        let alt = Self.escape(image.plainText)
        return "<img src=\"\(source)\" alt=\"\(alt)\">"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "<br>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        "<blockquote>\n\(defaultVisit(blockQuote))</blockquote>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        "<ul>\n\(defaultVisit(unorderedList))</ul>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        "<ol>\n\(defaultVisit(orderedList))</ol>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        "<li>\(defaultVisit(listItem))</li>\n"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        inlineHTML.rawHTML
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        html.rawHTML
    }

    /// Tables carry most of the guide's reference material, so this is
    /// written out rather than left to `defaultVisit`, which would emit
    /// the cell text as a run of prose with the structure gone.
    mutating func visitTable(_ table: Table) -> String {
        var out = "<table>\n<thead>\n<tr>"
        for cell in table.head.cells {
            out += "<th>\(defaultVisit(cell))</th>"
        }
        out += "</tr>\n</thead>\n<tbody>\n"
        for row in table.body.rows {
            out += "<tr>"
            for cell in row.cells {
                out += "<td>\(defaultVisit(cell))</td>"
            }
            out += "</tr>\n"
        }
        out += "</tbody>\n</table>\n"
        return out
    }
}
