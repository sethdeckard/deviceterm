// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Which parts of a target's accessibility tree this harness will walk.
///
/// macOS owns and populates the leading Apple menu, so its descendants belong
/// to the system rather than to whichever application was asked for. Position
/// is the ownership signal because the titles are localized, so matching those
/// would quietly stop working on a non-English system.
///
/// Shared by the dump and the input driver, so a dump does not carry the Apple
/// menu's contents and a press cannot match the menu or anything inside it.
/// One implementation rather than two, because the rule only holds if both
/// walks apply it.
enum AXTraversalPolicy {
    /// Role of a top-level item in an application's menu bar.
    static let menuBarItemRole = "AXMenuBarItem"

    /// Whether a walk should enter `role`, sitting at `siblingIndex` among its
    /// parent's children.
    ///
    /// A leading child whose role would not read is refused. The rule cannot
    /// tell whether it is the Apple menu, and the two mistakes do not cost the
    /// same: refusing omits that node's descendants from a dump and puts the
    /// subtree beyond the input driver's search, while admitting it puts
    /// system actions such as Sleep and Log Out within reach of a press.
    static func shouldEnter(role: String?, siblingIndex: Int) -> Bool {
        guard siblingIndex == 0 else { return true }
        guard let role else { return false }
        return role != menuBarItemRole
    }
}
