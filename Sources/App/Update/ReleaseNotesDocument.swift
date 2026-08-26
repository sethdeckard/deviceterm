// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A deliberately tiny HTML reader for the release
/// notes the Sparkle appcast carries in its <description>. It handles only
/// the grammar those notes are authored in, not real HTML:
///
///     <h1>/<h2>  → title      <b>/<strong> → strong    <br> → line break
///     <h3>…<h6>  → heading    <i>/<em>     → emphasis
///     <p>        → paragraph  <code>       → code
///     <li>       → bullet     <a href>     → link
///     <ul>/<ol>  transparent
///
/// <style>, <script>, declarations, and comments are dropped along with
/// their content. A fragment may carry a stylesheet, and its CSS must never
/// reach the popover as text. Any other unknown tag is ignored while its
/// text is kept, so an unexpected element costs formatting, not content.
///
/// Pure and Sendable, so it is unit-testable without any UI. Backs
/// UpdatePopoverView.
enum ReleaseNotesDocument {
    /// Returns no blocks when the fragment carries no renderable text,
    /// which the popover shows as its "no release notes" placeholder.
    static func parse(_ html: String) -> [ReleaseNotesBlock] {
        var parser = Parser()
        parser.consume(html)
        return parser.finished()
    }
}

private extension ReleaseNotesDocument {
    /// Which block the parser is filling. `nil` means loose text outside
    /// any block element, which flushes as a paragraph.
    enum BlockKind {
        case title
        case heading
        case paragraph
        case bullet
    }

    /// One still-open inline element. `link` is set only for `<a href>`.
    struct InlineTag {
        let name: String
        let link: URL?
    }

    /// A parsed `<…>`, ending at the index just past its `>`. Attribute
    /// names are lowercased and their values already entity-decoded.
    struct Tag {
        let name: String
        let isClosing: Bool
        /// `<br/>` and friends: an opening tag that closes itself, so it
        /// must never push onto the inline stack.
        let isSelfClosing: Bool
        let attributes: [String: String]
        let end: String.Index
    }

    /// One `name` or `name=value` pair, and where the caller resumes.
    struct Attribute {
        let name: String
        let value: String
        let end: String.Index
    }

    struct Parser {
        private var blocks: [ReleaseNotesBlock] = []
        private var buffer = AttributedString()
        private var kind: BlockKind?
        private var inline: [InlineTag] = []

        /// Whether the buffer already ends in whitespace, so the next text
        /// run drops its leading whitespace instead of doubling it. An
        /// empty buffer counts as whitespace, which trims the block's
        /// leading indentation as it arrives.
        private var trailingIsWhitespace: Bool {
            guard let last = buffer.characters.last else { return true }
            return last.isWhitespace
        }

        private var inlineIntents: InlinePresentationIntent {
            var intents: InlinePresentationIntent = []
            for tag in inline {
                switch tag.name {
                case "b", "strong":
                    intents.insert(.stronglyEmphasized)

                case "i", "em":
                    intents.insert(.emphasized)

                case "code":
                    intents.insert(.code)

                default:
                    break
                }
            }
            return intents
        }

        mutating func consume(_ html: String) {
            var index = html.startIndex
            while index < html.endIndex {
                guard html[index] == "<" else {
                    let next = html[index...].firstIndex(of: "<") ?? html.endIndex
                    appendText(String(html[index..<next]))
                    index = next
                    continue
                }
                if html[index...].hasPrefix("<!--") {
                    index = ReleaseNotesDocument.skip(past: "-->", in: html, from: index)
                    continue
                }
                if html[index...].hasPrefix("<!") {
                    index = ReleaseNotesDocument.skip(past: ">", in: html, from: index)
                    continue
                }
                guard let tag = ReleaseNotesDocument.tag(in: html, at: index) else {
                    // A bare `<` that starts no tag is content, not markup.
                    appendText("<")
                    index = html.index(after: index)
                    continue
                }
                index = tag.end
                if tag.name == "style" || tag.name == "script" {
                    if !tag.isClosing {
                        index = ReleaseNotesDocument.skip(past: "</\(tag.name)>", in: html, from: index)
                    }
                    continue
                }
                handle(tag)
            }
        }

        /// Flush whatever the last tag left open and hand back the blocks.
        mutating func finished() -> [ReleaseNotesBlock] {
            flush()
            return blocks
        }

        private mutating func handle(_ tag: Tag) {
            switch tag.name {
            case "h1", "h2":
                flush()
                if !tag.isClosing { kind = .title }

            case "h3", "h4", "h5", "h6":
                flush()
                if !tag.isClosing { kind = .heading }

            case "p":
                flush()
                if !tag.isClosing { kind = .paragraph }

            case "li":
                flush()
                if !tag.isClosing { kind = .bullet }

            case "ul", "ol":
                flush()

            case "br":
                appendBreak()

            case "b", "strong", "i", "em", "code", "a":
                handleInline(tag)

            default:
                break
            }
        }

        private mutating func handleInline(_ tag: Tag) {
            if tag.isClosing {
                // Close the innermost match. A close with nothing to match
                // is ignored rather than closing some other element, so an
                // unpaired one leaves its block's styling as the author
                // wrote it; `flush` is what stops it going further.
                if let open = inline.lastIndex(where: { $0.name == tag.name }) {
                    inline.remove(at: open)
                }
            } else if !tag.isSelfClosing {
                inline.append(
                    InlineTag(name: tag.name, link: tag.attributes["href"].flatMap { URL(string: $0) })
                )
            }
        }

        private mutating func appendText(_ raw: String) {
            var collapsed = ""
            var lastWasSpace = trailingIsWhitespace
            for character in ReleaseNotesDocument.decodingEntities(raw) {
                guard character.isWhitespace else {
                    collapsed.append(character)
                    lastWasSpace = false
                    continue
                }
                guard !lastWasSpace else { continue }
                collapsed.append(" ")
                lastWasSpace = true
            }
            guard !collapsed.isEmpty else { return }
            var run = AttributedString(collapsed)
            let intents = inlineIntents
            if !intents.isEmpty { run.inlinePresentationIntent = intents }
            if let link = inline.last(where: { $0.link != nil })?.link { run.link = link }
            buffer.append(run)
        }

        private mutating func appendBreak() {
            guard !buffer.characters.isEmpty else { return }
            buffer.append(AttributedString("\n"))
        }

        private mutating func flush() {
            let text = ReleaseNotesDocument.trimming(buffer)
            let finished = kind
            buffer = AttributedString()
            kind = nil
            // Inline styling ends with its block. Without this an unclosed
            // <b> in one list item would bold every item after it.
            inline.removeAll()
            guard !text.characters.isEmpty else { return }
            switch finished {
            case .title:
                blocks.append(.title(text))

            case .heading:
                blocks.append(.heading(text))

            case .bullet:
                blocks.append(.bullet(text))

            case .paragraph, nil:
                blocks.append(.paragraph(text))
            }
        }
    }

    /// The index just past `terminator`, or the end of input when it never
    /// appears. An unterminated comment or `<style>` swallows the rest
    /// rather than spilling its content into the notes.
    static func skip(past terminator: String, in html: String, from start: String.Index) -> String.Index {
        let remainder = start..<html.endIndex
        guard let found = html.range(of: terminator, options: [.caseInsensitive], range: remainder) else {
            return html.endIndex
        }
        return found.upperBound
    }

    /// Read the tag beginning at `start` (which must be its `<`). Returns
    /// `nil` when no `>` closes it, leaving the caller to treat the `<` as
    /// text.
    static func tag(in html: String, at start: String.Index) -> Tag? {
        var index = html.index(after: start)
        var isClosing = false
        if index < html.endIndex, html[index] == "/" {
            isClosing = true
            index = html.index(after: index)
        }
        var name = ""
        while index < html.endIndex, html[index].isLetter || html[index].isNumber {
            name.append(html[index])
            index = html.index(after: index)
        }
        guard !name.isEmpty else { return nil }
        var attributes: [String: String] = [:]
        var isSelfClosing = false
        while index < html.endIndex {
            let character = html[index]
            if character.isWhitespace {
                index = html.index(after: index)
                continue
            }
            if character == ">" {
                return Tag(
                    name: name.lowercased(),
                    isClosing: isClosing,
                    isSelfClosing: isSelfClosing,
                    attributes: attributes,
                    end: html.index(after: index)
                )
            }
            if character == "/" {
                // Only a solidus still standing when the `>` arrives closes
                // the tag. One inside a bare value (`href=https://host/`)
                // never reaches here, because the value reader takes it.
                isSelfClosing = true
                index = html.index(after: index)
                continue
            }
            isSelfClosing = false
            let parsed = attribute(in: html, at: index)
            if !parsed.name.isEmpty { attributes[parsed.name] = parsed.value }
            index = parsed.end
        }
        return nil
    }

    /// Read one attribute beginning at `start`. A valueless attribute
    /// yields an empty value; an unreadable one yields an empty name and an
    /// index past the offending character.
    static func attribute(in html: String, at start: String.Index) -> Attribute {
        var index = start
        var name = ""
        while index < html.endIndex {
            let character = html[index]
            if character.isWhitespace || character == "=" || character == ">" || character == "/" { break }
            name.append(character)
            index = html.index(after: index)
        }
        guard !name.isEmpty else {
            // Not a name character (a stray `=`, say). Step over it so the
            // caller cannot spin on the same index.
            let next = index < html.endIndex ? html.index(after: index) : index
            return Attribute(name: "", value: "", end: next)
        }
        var cursor = index
        while cursor < html.endIndex, html[cursor].isWhitespace { cursor = html.index(after: cursor) }
        guard cursor < html.endIndex, html[cursor] == "=" else {
            return Attribute(name: name.lowercased(), value: "", end: index)
        }
        cursor = html.index(after: cursor)
        while cursor < html.endIndex, html[cursor].isWhitespace { cursor = html.index(after: cursor) }
        guard cursor < html.endIndex else {
            return Attribute(name: name.lowercased(), value: "", end: cursor)
        }
        var value = ""
        if html[cursor] == "\"" || html[cursor] == "'" {
            let quote = html[cursor]
            cursor = html.index(after: cursor)
            while cursor < html.endIndex, html[cursor] != quote {
                value.append(html[cursor])
                cursor = html.index(after: cursor)
            }
            if cursor < html.endIndex { cursor = html.index(after: cursor) }
        } else {
            while cursor < html.endIndex, !html[cursor].isWhitespace, html[cursor] != ">" {
                value.append(html[cursor])
                cursor = html.index(after: cursor)
            }
        }
        return Attribute(name: name.lowercased(), value: decodingEntities(value), end: cursor)
    }

    /// Decode the handful of entities these notes use. An unrecognized
    /// `&…;` is left exactly as written rather than dropped.
    static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&",
                let semicolon = text[index...].firstIndex(of: ";"),
                text.distance(from: index, to: semicolon) <= 12,
                let decoded = entity(named: String(text[text.index(after: index)..<semicolon])) else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }
            result.append(decoded)
            index = text.index(after: semicolon)
        }
        return result
    }

    static func entity(named name: String) -> Character? {
        let key = name.lowercased()
        switch key {
        case "amp":
            return "&"

        case "lt":
            return "<"

        case "gt":
            return ">"

        case "quot":
            return "\""

        case "apos":
            return "'"

        case "nbsp":
            return " "

        default:
            guard key.hasPrefix("#") else { return nil }
            let digits = key.dropFirst()
            let scalar = digits.hasPrefix("x")
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits, radix: 10)
            guard let scalar, let value = Unicode.Scalar(scalar) else { return nil }
            return Character(value)
        }
    }

    static func trimming(_ text: AttributedString) -> AttributedString {
        var result = text
        while let first = result.characters.first, first.isWhitespace {
            result.removeSubrange(result.startIndex..<result.characters.index(after: result.startIndex))
        }
        while let last = result.characters.last, last.isWhitespace {
            result.removeSubrange(result.characters.index(before: result.endIndex)..<result.endIndex)
        }
        return result
    }
}
