// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Which path a menu item is being validated for.
enum MenuActionOrigin: Equatable, Sendable {
    /// A key equivalent matching the item's own chord.
    case keyEquivalent
    /// A click, a menu-tracking update, or anything else.
    case pointerOrMenu
}
