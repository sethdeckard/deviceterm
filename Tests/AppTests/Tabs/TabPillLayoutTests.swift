// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import Testing

/// The priority band the tab pills lay out in.
///
/// The strip is the window's content root, so any of these landing above the
/// window-drag threshold stops the window being dragged narrower, and does it
/// without a constraint error to notice: AppKit constrains the window frame
/// instead of compressing the pill. A layout test cannot see that. `fittingSize`
/// solves at `.fittingSizeCompression`, far below this band, so it returns the
/// same answer whether or not the bug is present. The band is the contract.
@MainActor
struct TabPillLayoutTests {
    /// Named, so a failure says which constant broke the rule.
    private static var band: [(name: String, priority: NSLayoutConstraint.Priority)] {
        [
            ("title", TabPillLayout.titleCompression),
            ("shortcutBadge", TabPillLayout.shortcutBadgeCompression),
            ("marker", TabPillLayout.markerCompression),
            ("closeButton", TabPillLayout.closeButtonCompression),
            ("cellMinimumWidth", TabPillLayout.cellMinimumWidthPriority),
            ("stackTrailingPin", TabPillLayout.stackTrailingPin),
            ("soloPillTarget", TabPillLayout.soloPillTarget),
            ("frozenWidthPin", TabPillLayout.frozenWidthPin)
        ]
    }

    @Test
    func everyPillPriorityYieldsToAWindowDrag() {
        for entry in Self.band {
            #expect(
                entry.priority.rawValue < NSLayoutConstraint.Priority.dragThatCanResizeWindow.rawValue,
                "\(entry.name) outranks a window drag, so it becomes the window's minimum width"
            )
        }
    }

    /// AppKit reserves this exact value for the window's own preference to hold
    /// its size, and says content should sit either side of it rather than on
    /// it. A tie there resolves arbitrarily.
    @Test
    func noPillPrioritySitsOnTheWindowsOwn() {
        for entry in Self.band {
            #expect(
                entry.priority != .windowSizeStayPut,
                "\(entry.name) ties with the window's own size preference"
            )
        }
    }

    /// The order a crowded pill sheds what it shows: the title truncates into
    /// something still readable, the badge's chord is also in the Window menu,
    /// the markers carry state nothing else repeats, and the ✕ keeps the tab
    /// closeable.
    @Test
    func theDegradationOrderRunsTitleToCloseButton() {
        #expect(
            TabPillLayout.titleCompression.rawValue
                < TabPillLayout.shortcutBadgeCompression.rawValue
        )
        #expect(
            TabPillLayout.shortcutBadgeCompression.rawValue
                < TabPillLayout.markerCompression.rawValue
        )
        #expect(
            TabPillLayout.markerCompression.rawValue
                < TabPillLayout.closeButtonCompression.rawValue
        )
    }

    /// A cell with room to grow takes it before any of its contents is
    /// squashed, so the preferred width outranks all of them.
    @Test
    func wideningACellBeatsSquashingItsContents() {
        #expect(
            TabPillLayout.closeButtonCompression.rawValue
                < TabPillLayout.cellMinimumWidthPriority.rawValue
        )
    }

    /// The freeze exists so a run of ✕ clicks lands on one spot, which means a
    /// rebuild mid-run must not widen the pill back to its preferred width
    /// under a pointer that has not moved.
    @Test
    func aFrozenWidthOutranksThePreferredWidth() {
        #expect(
            TabPillLayout.cellMinimumWidthPriority.rawValue
                < TabPillLayout.frozenWidthPin.rawValue
        )
    }

    /// The badge is dropped outright rather than compressed to a fragment, and
    /// only once the pill is already below the width it would rather have.
    @Test
    func theBadgeDropsOnlyOnAnAlreadyNarrowPill() {
        #expect(TabPillLayout.shortcutVisibilityWidth < TabPillLayout.cellMinimumWidth)
    }
}
