// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// One NSWindow hosting a tab's content. The
/// content is a TabStripViewController root that hosts every tab in
/// the window; multi-window is supported.
@MainActor
final class WindowController: NSWindowController {
    /// The window's minimum content size, also the floor for the default size
    /// on a very small display.
    static let minContentSize = NSSize(width: 800, height: 500)

    convenience init(content: NSViewController) {
        let size = Self.defaultContentSize()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Native title bar visible above the tab strip. Title text shows the focused tab/pane name; the
        // bar itself is rendered transparent so the window's
        // backgroundColor (= ghostty `background` config) tints it,
        // matching the strip and pane chrome below for one cohesive
        // palette. With `.fullSizeContentView` on, the content view
        // extends under the title bar, so the tab strip's top
        // constraint reserves the title-bar height as its inset.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.title = "DeviceTerm"
        if let tint = GhosttyThemeColors.cachedBackground() {
            window.backgroundColor = tint
        }
        window.minSize = Self.minContentSize
        self.init(window: window)
        window.contentViewController = content
        // Assigning the content view controller resizes the window to its
        // view's frame, clobbering the contentRect above, so re-assert the
        // intended size afterward, then center.
        window.setContentSize(size)
        window.center()
    }

    /// The size a brand-new window opens at. deviceterm starts a bit taller than a
    /// stock terminal on purpose: a tab almost always grows a device pane (often
    /// a portrait iPhone) beside the terminal, which needs the extra height, so
    /// opening short just forces an immediate resize the moment the pane
    /// attaches. The size is responsive: it scales with the display rather than
    /// being fixed.
    static func defaultContentSize(screen: NSScreen? = NSScreen.main) -> NSSize {
        defaultContentSize(visibleScreen: screen?.visibleFrame.size)
    }

    /// Screen-free core (unit-tested). Window height as a fraction of usable
    /// screen height follows a deliberate curve: ~90% on small displays, easing
    /// to ~60% at a typical large display, down to ~50% on the biggest. That
    /// falls out of four pixel bounds applied to `heightFraction × screenH`:
    /// a `floor` that keeps small screens tall (raising their %), a `cap` that
    /// bends large screens down (lowering their %), then screen-relative bounds
    /// that hold the result between 50% and 90% of the screen. Width tracks
    /// height at the terminal + device-pane aspect. `nil` (no screen) returns a
    /// neutral default.
    static func defaultContentSize(visibleScreen: NSSize?) -> NSSize {
        let heightFraction = 0.60
        let floor = 760.0
        let cap = 1_100.0
        let aspect = 1.2 // width : height
        guard let visible = visibleScreen else {
            return NSSize(width: 1_280, height: 1_000)
        }
        var height = min(cap, max(floor, visible.height * heightFraction))
        height = min(height, visible.height * 0.90) // never more than 90% of the screen
        height = max(height, visible.height * 0.50) // never less than 50% of the screen
        height = max(height, Self.minContentSize.height)
        var width = min(height * aspect, visible.width * 0.90)
        width = max(width, Self.minContentSize.width)
        return NSSize(width: width.rounded(), height: height.rounded())
    }

    /// Place the window with its top-left near `screenPoint` (the tab
    /// tear-off drop location), clamped so the title bar stays grabbable
    /// on whatever screen contains the point. Used instead of `center()`
    /// for a torn-off tab's new window so it lands under the cursor.
    func position(topLeftNear screenPoint: NSPoint) {
        guard let window else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(screenPoint) }
            ?? NSScreen.main
        var origin = screenPoint
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - 120)
            origin.y = min(max(origin.y, visible.minY + 120), visible.maxY)
        }
        window.setFrameTopLeftPoint(origin)
    }
}
