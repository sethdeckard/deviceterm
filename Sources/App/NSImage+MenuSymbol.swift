// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

extension NSImage {
    /// A menu item's leading symbol, sized for the menu's icon column.
    ///
    /// Callers choose which items receive symbols. The image stays a template,
    /// so a highlighted row tints it along with its text, which is why the tab
    /// strip's teal and orange do not follow its markers into the menus.
    ///
    /// `fallback` names a second symbol to try when the running macOS lacks
    /// `name`. Resolution fails by returning nil rather than by throwing, so a
    /// name the host does not vend costs its item the whole icon and nothing
    /// reports it. Choose a fallback available at the deployment target in
    /// `Package.swift`.
    static func menuSymbol(
        _ name: String,
        describedAs: String,
        fallback: String? = nil
    ) -> NSImage? {
        let resolved = NSImage(systemSymbolName: name, accessibilityDescription: describedAs)
            ?? fallback.flatMap {
                NSImage(systemSymbolName: $0, accessibilityDescription: describedAs)
            }
        // `withSymbolConfiguration` vends a new instance, so the template flag
        // has to land on the derived image rather than on the original.
        let sized = resolved?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
        sized?.isTemplate = true
        return sized
    }
}
