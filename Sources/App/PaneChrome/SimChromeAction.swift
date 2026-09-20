// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Observation

/// One of the ribbon's interactive actions. Tracked in the chrome view
/// model as `lastUsedAction` so the narrowest reveal stop can show the most
/// recently invoked control. Device family selects which subset of
/// cases the row reveals
/// (phone/pad → home/rotate; watch → crownPress/up/down; etc.).
enum SimChromeAction: Sendable, Equatable, Hashable {
    case home
    case appSwitcher
    case lock
    case side
    case siri
    case applePay
    case rotateLeft
    case rotateRight
    case screenshot
    case record
    case axInspector
    case crownPress
    case crownUp
    case crownDown

    /// SF Symbol for the App Switcher, resolved against the running macOS.
    ///
    /// Resolved here rather than at each call site because the ribbon, the
    /// Device menu, and the pane's context menu all draw this action and must
    /// agree. Uses `iphone.app.switcher` on macOS 15 or later and
    /// `square.grid.2x2` on earlier versions.
    ///
    /// The choice is made up front instead of through
    /// `NSImage.menuSymbol`'s `fallback`, because SwiftUI's
    /// `Image(systemName:)` is non-failable and cannot fall back on a nil.
    static var appSwitcherSymbol: String {
        if #available(macOS 15, *) {
            return "iphone.app.switcher"
        }
        return "square.grid.2x2"
    }
}
