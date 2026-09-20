// SPDX-License-Identifier: GPL-3.0-or-later

/// When the tab strip holds its pill widths instead of re-flowing them.
///
/// Closing a tab normally widens every survivor, which walks the next ✕ out
/// from under a pointer that has not moved. Holding the widths until the
/// pointer leaves lets a run of closes land on one spot.
///
/// Pure, so both rules are testable without a window, the way
/// `TabSeparatorDecision` already is. The constraint work they gate is not.
enum TabWidthFreezeDecision {
    /// What asked for a tab to close.
    enum CloseOrigin: Equatable {
        /// A click on a pill's ✕.
        case closeButton
        /// ⌘W, the tab context menu, the CLI, or a shell exit.
        case elsewhere
    }

    /// Whether this close should pin the strip's current widths.
    ///
    /// Only a ✕ click does, and only with the pointer still over the strip.
    /// Other close routes never start a freeze whatever the pointer is doing:
    /// ⌘W or `deviceterm tab close` can fire with it over the strip by
    /// coincidence, and that is not a run of clicks to protect. The pointer
    /// test then covers a ✕ activated through accessibility, where there may
    /// be no pointer near the strip at all.
    static func shouldFreeze(origin: CloseOrigin, pointerIsOverStrip: Bool) -> Bool {
        origin == .closeButton && pointerIsOverStrip
    }

    /// Whether a change in tab count releases the freeze.
    ///
    /// A frozen strip is mid-run, so the list shrinking is the close it was
    /// frozen for and the widths stay. Anything else means the strip is no
    /// longer the shape the freeze was measured against: a tab opening, or a
    /// pill dropped in from another window, both want the normal re-flow.
    static func shouldThawOnTabCountChange(from previous: Int, to current: Int) -> Bool {
        current >= previous
    }
}
