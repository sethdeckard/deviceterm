// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

extension NSImage {
    /// A menu item's leading symbol, sized for the menu's icon column.
    ///
    /// Callers choose which items receive symbols. The image stays a template,
    /// so a highlighted row tints it along with its text, which is why the tab
    /// strip's teal and orange do not follow its markers into the menus.
    static func menuSymbol(_ name: String, describedAs: String) -> NSImage? {
        // `withSymbolConfiguration` vends a new instance, so the template flag
        // has to land on the derived image rather than on the original.
        let sized = NSImage(systemSymbolName: name, accessibilityDescription: describedAs)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        sized?.isTemplate = true
        return sized
    }
}
