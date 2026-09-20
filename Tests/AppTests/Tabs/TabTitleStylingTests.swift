// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import Testing

/// Pins the pill title's attributed rendering: which color marks selection,
/// and the attributes an attributed title has to restate because it replaces
/// the ones the button carries.
@MainActor
struct TabTitleStylingTests {
    /// A button configured the way `rebuildStrip` builds a pill title, so the
    /// attributes carried forward are read from the same starting point the
    /// strip uses.
    private func titleButton() -> NSButton {
        let button = NSButton(title: "placeholder", target: nil, action: nil)
        button.isBordered = false
        button.lineBreakMode = .byTruncatingTail
        button.cell?.usesSingleLineMode = true
        return button
    }

    private func attributes(of button: NSButton) -> [NSAttributedString.Key: Any] {
        button.attributedTitle.attributes(at: 0, effectiveRange: nil)
    }

    /// The whole point of the pair, so it is asserted before anything reads a
    /// specific one: were they equal, every other test here would pass while
    /// selection read identically to the rest of the strip.
    @Test
    func theSelectedAndUnselectedColorsDiffer() {
        #expect(NSColor.labelColor != NSColor.secondaryLabelColor)
    }

    @Test
    func aSelectedTitleUsesTheLabelColor() {
        let button = titleButton()
        TabStripViewController.applyTitleStyling(to: button, text: "shell", isSelected: true)
        #expect(attributes(of: button)[.foregroundColor] as? NSColor == .labelColor)
    }

    @Test
    func anUnselectedTitleUsesTheSecondaryLabelColor() {
        let button = titleButton()
        TabStripViewController.applyTitleStyling(to: button, text: "shell", isSelected: false)
        #expect(attributes(of: button)[.foregroundColor] as? NSColor == .secondaryLabelColor)
    }

    @Test(arguments: [true, false])
    func theTextIsCarriedThrough(isSelected: Bool) {
        let button = titleButton()
        TabStripViewController.applyTitleStyling(
            to: button,
            text: "~/projects/deviceterm",
            isSelected: isSelected
        )
        #expect(button.attributedTitle.string == "~/projects/deviceterm")
    }

    /// An attributed title brings its own paragraph style, so the truncation
    /// the button was built with no longer reaches the text. A pill that stops
    /// truncating pushes its close button past the cell's trailing edge.
    @Test
    func truncationSurvivesTheAttributedTitle() {
        let button = titleButton()
        TabStripViewController.applyTitleStyling(to: button, text: "shell", isSelected: true)
        let paragraph = attributes(of: button)[.paragraphStyle] as? NSParagraphStyle
        #expect(paragraph?.lineBreakMode == .byTruncatingTail)
    }

    @Test
    func alignmentFollowsTheButton() {
        let button = titleButton()
        button.alignment = .left
        TabStripViewController.applyTitleStyling(to: button, text: "shell", isSelected: true)
        let paragraph = attributes(of: button)[.paragraphStyle] as? NSParagraphStyle
        #expect(paragraph?.alignment == .left)
    }

    /// Restyling is what both render passes do on every tick, so it has to be
    /// idempotent rather than accumulating attributes or stale text.
    @Test
    func restylingReplacesRatherThanAccumulates() {
        let button = titleButton()
        TabStripViewController.applyTitleStyling(to: button, text: "first", isSelected: true)
        TabStripViewController.applyTitleStyling(to: button, text: "second", isSelected: false)
        #expect(button.attributedTitle.string == "second")
        #expect(attributes(of: button)[.foregroundColor] as? NSColor == .secondaryLabelColor)
    }
}
