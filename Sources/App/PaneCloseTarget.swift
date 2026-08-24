// SPDX-License-Identifier: GPL-3.0-or-later

enum PaneCloseTarget: Equatable, Sendable {
    case pane(PaneSlot)
    case tab
}
