// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The typographic decisions the update popover makes about a
/// parsed release-notes document, kept apart from the view so they are
/// testable without instantiating one. Backs `UpdatePopoverView`.
enum ReleaseNotesStyle {
    /// The gap above `block`, given the block that precedes it, or `nil`
    /// for the first block in the document.
    ///
    /// The ratio between the results carries the layout, not the absolute
    /// values: a section heading opens with far more air than sibling
    /// bullets take between them, which is what lets a list read as one
    /// grouped run and a heading read as a break. A heading binds down to
    /// the content it introduces, so it takes more space above than below.
    static func topSpacing(after previous: ReleaseNotesBlock?, before block: ReleaseNotesBlock) -> CGFloat {
        guard let previous else { return 0 }

        switch (previous, block) {
        case (_, .heading):
            return 18

        case (_, .title):
            return 14

        case (.title, _), (.heading, _):
            return 6

        case (.bullet, .bullet):
            return 4

        case (.bullet, .paragraph):
            return 12

        case (.paragraph, .bullet):
            return 8

        case (.paragraph, .paragraph):
            return 10
        }
    }

    /// `text` with `font` set on every `<code>` run and nothing else
    /// touched.
    ///
    /// A monospaced face set at the surrounding point size reads wider and
    /// heavier than the prose around it, so the caller passes one semantic
    /// step down. Runs that are not code keep no font of their own, which
    /// leaves the view's own `.font(_:)` governing them.
    static func applyingCodeFont(_ text: AttributedString, _ font: Font) -> AttributedString {
        var result = text
        var codeRanges: [Range<AttributedString.Index>] = []

        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            codeRanges.append(run.range)
        }

        // Setting an attribute leaves the characters alone, so ranges
        // collected from `result` stay valid as the loop assigns into it.
        for range in codeRanges {
            result[range].font = font
        }

        return result
    }
}
