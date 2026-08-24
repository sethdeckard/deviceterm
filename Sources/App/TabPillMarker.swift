// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// One marker a tab pill can carry. Each sits between the pill's close
/// control and its title, in the order `TabMarkerDecision` returns them.
enum TabPillMarker: Equatable {
    /// The tab's session was minted with the automation role.
    case automation
    /// The tab is hidden from other sessions right now.
    case protection
}
