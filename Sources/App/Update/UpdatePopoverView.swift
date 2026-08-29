// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The expanded form of the update pill, showing the new
/// version, the release notes (the appcast's HTML description, parsed into
/// blocks and laid out natively), and Install / Later actions. Shown in a
/// popover anchored to the pill when the user clicks its notes disclosure.
///
/// The app owns the notes' typography: blocks carry no color of their own,
/// so both appearances follow from the semantic styles here, and the rhythm
/// between them comes from `ReleaseNotesStyle`.
struct UpdatePopoverView: View {
    /// Monospaced runs one semantic step below the prose they sit in, so a
    /// `<code>` span reads level with its surroundings rather than heavier.
    private static let bodyCodeFont = Font.system(.subheadline, design: .monospaced)
    private static let headingCodeFont = Font.system(.callout, design: .monospaced)

    let version: String
    let notes: String?
    let install: () -> Void
    let later: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Version \(version) is available")
                .font(.title3.weight(.semibold))

            Divider()

            ScrollView {
                notesBody
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 4)
            }
            .frame(maxHeight: 420)
            .scrollBounceBehavior(.basedOnSize)
            .textSelection(.enabled)

            Divider()

            HStack {
                Button("Later", action: later)
                Spacer()
                Button("Install", action: install)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    @ViewBuilder private var notesBody: some View {
        let blocks = ReleaseNotesDocument.parse(notes ?? "")
        if blocks.isEmpty {
            Text("No release notes for this version.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            // Spacing rides on each block's top padding rather than on the
            // stack, because what the gap should be depends on the pair.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { offset, block in
                    blockView(block)
                        .padding(.top, ReleaseNotesStyle.topSpacing(
                            after: offset == 0 ? nil : blocks[offset - 1],
                            before: block
                        ))
                }
            }
        }
    }

    /// Notes authored for a release skip a title, so a `.title` reaching
    /// here is a stray `<h1>`/`<h2>`; it renders as a section heading so
    /// its text survives without earning styling of its own.
    @ViewBuilder
    private func blockView(_ block: ReleaseNotesBlock) -> some View {
        switch block {
        case let .title(text), let .heading(text):
            Text(ReleaseNotesStyle.applyingCodeFont(text, Self.headingCodeFont))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

        case let .paragraph(text):
            Text(ReleaseNotesStyle.applyingCodeFont(text, Self.bodyCodeFont))
                .font(.callout)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

        case let .bullet(text):
            // Keeping the glyph and the text in separate HStack children is
            // what aligns wrapped lines under the text rather than under the
            // glyph; firstTextBaseline aligns their first lines.
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(ReleaseNotesStyle.applyingCodeFont(text, Self.bodyCodeFont))
                    .font(.callout)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 2)
        }
    }
}
