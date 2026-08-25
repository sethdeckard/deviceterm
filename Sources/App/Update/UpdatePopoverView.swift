// SPDX-License-Identifier: GPL-3.0-or-later
//
// UpdatePopoverView: the expanded form of the update pill, showing the new
// version, the release notes (the appcast's HTML description, parsed into
// blocks and laid out natively), and Install / Later actions. Shown in a
// popover anchored to the pill when the user clicks its notes disclosure.
//
// The app owns the notes' typography: blocks carry no color of their own,
// so both appearances follow from the semantic styles here.

import SwiftUI

struct UpdatePopoverView: View {
    let version: String
    let notes: String?
    let install: () -> Void
    let later: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Version \(version) is available")
                .font(.headline)

            Divider()

            ScrollView {
                notesBody
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 340)
            .textSelection(.enabled)

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
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ReleaseNotesBlock) -> some View {
        switch block {
        case let .title(text):
            Text(text).font(.headline)

        case let .heading(text):
            Text(text)
                .font(.callout.weight(.semibold))
                .padding(.top, 6)

        case let .paragraph(text):
            Text(text).font(.callout)

        case let .bullet(text):
            // Keeping the glyph and the text in separate HStack children is
            // what aligns wrapped lines under the text rather than under the
            // glyph; firstTextBaseline aligns their first lines.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 4)
        }
    }
}
