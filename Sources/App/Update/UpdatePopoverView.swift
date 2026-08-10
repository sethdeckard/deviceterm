// SPDX-License-Identifier: GPL-3.0-or-later
//
// UpdatePopoverView: the expanded form of the update pill, showing the new
// version, the release notes (the appcast's HTML description, rendered to
// an AttributedString), and Install / Later actions. Shown in a popover
// anchored to the pill when the user clicks its notes disclosure.

import AppKit
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
            .frame(maxHeight: 240)

            HStack {
                Button("Later", action: later)
                Spacer()
                Button("Install", action: install)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    @ViewBuilder private var notesBody: some View {
        if let attributed = Self.renderNotes(notes) {
            Text(attributed)
                .font(.callout)
                .textSelection(.enabled)
        } else {
            Text("No release notes for this version.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Render the appcast's HTML release notes into an AttributedString,
    /// honoring the current appearance. Returns `nil` for empty/unparseable
    /// notes so the caller shows a placeholder.
    static func renderNotes(_ html: String?) -> AttributedString? {
        guard let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let data = html.data(using: .utf8) else {
            return nil
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let parsed = try? NSAttributedString(
            data: data,
            options: options,
            documentAttributes: nil
        ) else {
            // Not HTML (or failed to parse), so fall back to the raw text.
            return AttributedString(html)
        }
        return AttributedString(parsed)
    }
}
