// SPDX-License-Identifier: GPL-3.0-or-later
//
// MarkdownDocument: a deliberately tiny markdown parser for the
// bundled THIRD_PARTY_NOTICES.md. It handles only the grammar that
// document is authored in, not full CommonMark:
//
//   `# `        → title          (one per document)
//   `## `       → heading        (per-component)
//   ``` fences  → verbatim block (license texts, rendered monospaced)
//   other text  → paragraph      (blank-line separated; inline markdown
//                                  is interpreted by the view, not here)
//
// Pure + `Sendable` so it's unit-testable without any UI. Backs
// `ThirdPartyNoticesViewModel`.

import Foundation

enum MarkdownBlock: Equatable, Sendable {
    case title(String)
    case heading(String)
    case paragraph(String)
    case verbatim(String)
}

enum MarkdownDocument {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var verbatim: [String] = []
        var inVerbatim = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inVerbatim {
                    blocks.append(.verbatim(verbatim.joined(separator: "\n")))
                    verbatim.removeAll()
                    inVerbatim = false
                } else {
                    flushParagraph()
                    inVerbatim = true
                }
                continue
            }
            if inVerbatim {
                verbatim.append(line)
                continue
            }
            if line.hasPrefix("## ") {
                flushParagraph()
                blocks.append(.heading(String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") {
                flushParagraph()
                blocks.append(.title(String(line.dropFirst(2))))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        // Tolerate an unterminated fence rather than dropping its text.
        if inVerbatim, !verbatim.isEmpty {
            blocks.append(.verbatim(verbatim.joined(separator: "\n")))
        }
        return blocks
    }
}
