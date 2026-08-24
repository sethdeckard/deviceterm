// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum MarkdownBlock: Equatable, Sendable {
    case title(String)
    case heading(String)
    case paragraph(String)
    case verbatim(String)
}
