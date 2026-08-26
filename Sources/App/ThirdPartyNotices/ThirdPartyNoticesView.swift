// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Renders the parsed THIRD_PARTY_NOTICES.md.
/// Headings get weight/size; paragraphs interpret inline markdown
/// (emphasis/links) while preserving line breaks; verbatim license texts
/// render monospaced. All text is selectable.
struct ThirdPartyNoticesView: View {
    let viewModel: ThirdPartyNoticesViewModel

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .textSelection(.enabled)
        .frame(minWidth: 480, minHeight: 360)
    }

    @ViewBuilder private var content: some View {
        switch viewModel.state {
        case .loading:
            ProgressView()

        case .unavailable:
            Text("Third-party notices are unavailable in this build.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

        case let .loaded(blocks):
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .title(text):
            Text(text).font(.system(size: 20, weight: .bold))

        case let .heading(text):
            Text(text)
                .font(.system(size: 14, weight: .semibold))
                .padding(.top, 4)

        case let .paragraph(text):
            Text(inlineMarkdown(text)).font(.system(size: 12))

        case let .verbatim(text):
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Interpret inline markdown (bold/italic/links) while keeping the
    /// paragraph's own line breaks. Falls back to plain text if parsing
    /// fails.
    private func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
    }
}
