// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import Testing

// The default new-window size scales to the display so a device pane (often a
// portrait iPhone) has room beside the terminal without an immediate resize.

@MainActor
@Test("default window height follows the responsive curve (90%→60%→50%)")
func defaultWindowSizeFollowsCurve() {
    // No screen → a neutral default.
    #expect(WindowController.defaultContentSize(visibleScreen: nil) == NSSize(width: 1_280, height: 1_000))

    // A large display sits in the 60% band: 0.60 × 1770 = 1062; width 1.2×.
    let large = WindowController.defaultContentSize(visibleScreen: NSSize(width: 3_200, height: 1_770))
    #expect(large == NSSize(width: 1_274, height: 1_062))

    // 1440p, still the 60% band (0.60 × 1440 = 864).
    let twoK = WindowController.defaultContentSize(visibleScreen: NSSize(width: 2_560, height: 1_440))
    #expect(twoK == NSSize(width: 1_037, height: 864))

    // 1080p rides the 760 floor (raw 0.60 × 1080 = 648 < 760), ≈70% of height.
    let fullHD = WindowController.defaultContentSize(visibleScreen: NSSize(width: 1_920, height: 1_080))
    #expect(fullHD == NSSize(width: 912, height: 760))

    // An extreme display floors at 50% of height (cap 1100 < 0.50 × 2880).
    let huge = WindowController.defaultContentSize(visibleScreen: NSSize(width: 5_120, height: 2_880))
    #expect(huge == NSSize(width: 1_728, height: 1_440))

    // A small display is bounded to 90% of the screen so it still fits.
    let small = WindowController.defaultContentSize(visibleScreen: NSSize(width: 1_366, height: 768))
    #expect(small == NSSize(width: 829, height: 691))

    // A tiny display never drops below the window minimum.
    let tiny = WindowController.defaultContentSize(visibleScreen: NSSize(width: 800, height: 500))
    #expect(tiny == NSSize(width: 800, height: 500))
}
