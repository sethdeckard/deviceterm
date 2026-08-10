// SPDX-License-Identifier: GPL-3.0-or-later
//
// TabStripChromeTests: pin the window-chrome contract: a
// transparent native title bar with the title text VISIBLE (showing
// the focused pane / tab name), with the tab strip mounted below it
// inside the same `.fullSizeContentView` content area. The strip
// reports its empty regions as draggable so click-and-drag on
// background space still moves the window.

@testable import App
import AppKit
import Testing

@MainActor
struct TabStripChromeTests {
    /// Bring the window up via the same convenience initializer
    /// AppDelegate uses; assert the chrome bits land where the
    /// title-bar-collapse design says they should.
    @Test
    func windowChromeFlagsMatchGhosttyArrangement() {
        let placeholder = NSViewController()
        placeholder.view = NSView(frame: .zero)
        let controller = WindowController(content: placeholder)
        guard let window = controller.window else {
            Issue.record("WindowController produced no window")
            return
        }
        // `.fullSizeContentView` + transparent title bar lets the
        // window's backgroundColor (ghostty `background` tint) paint
        // both the title bar and the strip area as one cohesive
        // surface. `titleVisibility = .visible` keeps the focused
        // pane / tab name showing in the title bar, Ghostty's shape.
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titlebarAppearsTransparent == true)
        #expect(window.titleVisibility == .visible)
    }

    @Test
    func windowTitleIsSetAtCreation() {
        let placeholder = NSViewController()
        placeholder.view = NSView(frame: .zero)
        let controller = WindowController(content: placeholder)
        guard let window = controller.window else {
            Issue.record("WindowController produced no window")
            return
        }
        #expect(window.title.isEmpty == false)
    }
}
