// SPDX-License-Identifier: GPL-3.0-or-later
//
// ReleaseNotesBlock: one laid-out block of an update's release notes.
// `ReleaseNotesDocument` produces these from the appcast's HTML and the
// update popover gives each its own typography. Inline styling (bold,
// emphasis, code, links) rides on the AttributedString itself, so a block
// carries no formatting state of its own.

import Foundation

enum ReleaseNotesBlock: Equatable, Sendable {
    /// `<h1>`/`<h2>`: the notes' own title line.
    case title(AttributedString)
    /// `<h3>` and deeper: a section heading.
    case heading(AttributedString)
    /// `<p>`, or any loose text outside a block element.
    case paragraph(AttributedString)
    /// One `<li>`. The view supplies the glyph and the hanging indent.
    case bullet(AttributedString)
}
