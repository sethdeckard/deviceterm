// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// One marker a tab pill can carry. Each sits between the pill's close
/// control and its title, in the order `TabMarkerDecision` returns them. A
/// pinned pill draws its markers as its only content, in the order
/// `TabPinnedGlyphDecision` returns them.
enum TabPillMarker: Equatable {
    /// The tab's session was minted with the automation role.
    case automation
    /// The tab is hidden from other sessions right now.
    case protection
    /// A plain terminal tab. Only a pinned pill shows it, standing in for
    /// the title when the tab has no other marker to show.
    case terminal

    /// The SF Symbol the marker renders as.
    var symbolName: String {
        switch self {
        case .automation:
            return "bolt.fill"

        case .protection:
            return "lock.fill"

        case .terminal:
            return "terminal"
        }
    }

    /// The accessibility description of the marker's image.
    var accessibilityDescription: String {
        switch self {
        case .automation:
            return "Automation tab"

        case .protection:
            return "Protected tab"

        case .terminal:
            return "Terminal tab"
        }
    }

    /// What hovering the marker explains, nil for the terminal glyph, which
    /// says nothing the tab's title does not.
    var hoverText: String? {
        switch self {
        case .automation:
            return "Automation tab: can control other tabs and send input to their terminals"

        case .protection:
            return "Protected tab: hidden from other sessions and closed to automation"

        case .terminal:
            return nil
        }
    }
}
