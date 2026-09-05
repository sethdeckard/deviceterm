// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Markdown

/// One page of the help book: everything under a single `##` heading in
/// the source guide.
///
/// Help Viewer indexes and lists pages, not sections of a page, so the
/// split decides what a search can return. `##` is the level the guide's
/// own `## Contents` list already uses, which makes the topic set the one
/// its author chose rather than one this tool invented.
struct Topic {
    /// The `##` heading text, verbatim. Becomes the page's `AppleTitle`,
    /// which is the string Help Viewer shows in results.
    let title: String

    /// The anchor the source document links to this heading by, and the
    /// page's filename stem.
    let slug: String

    /// The blocks under the heading, excluding the heading itself. The
    /// page template renders the title, so leaving it in would print it
    /// twice.
    let body: [Markup]

    var fileName: String {
        "\(slug).html"
    }
}
