// SPDX-License-Identifier: GPL-3.0-or-later

import ApplicationServices
import CoreGraphics
import Foundation

enum AXAttribute {
    static let role = "AXRole"
    static let subrole = "AXSubrole"
    static let title = "AXTitle"
    static let value = "AXValue"
    static let description = "AXDescription"
    static let identifier = "AXIdentifier"
    static let help = "AXHelp"
    /// Whether this element holds keyboard focus. `AXFocusedWindow`
    /// answers only at window granularity, so this is what distinguishes
    /// one pane from its siblings.
    static let focused = "AXFocused"
    /// A window's represented file, as a URL string. This is what publishes the
    /// titlebar proxy icon, and the only way to assert the folder it resolves
    /// to from outside the app.
    static let document = "AXDocument"
    static let children = "AXChildren"
    static let position = "AXPosition"
    static let size = "AXSize"
    static let focusedWindow = "AXFocusedWindow"
    static let mainWindow = "AXMainWindow"
    static let windows = "AXWindows"
}
