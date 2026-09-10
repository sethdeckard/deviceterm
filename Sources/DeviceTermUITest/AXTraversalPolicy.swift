// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Which parts of a target's accessibility tree this harness will walk.
///
/// Two rules live here.
///
/// macOS owns and populates the leading Apple menu, so its descendants belong
/// to the system rather than to whichever application was asked for. Position
/// is the ownership signal because the titles are localized, so matching those
/// would quietly stop working on a non-English system.
///
/// An application element never legitimately contains another, so a nested one
/// is a malformed tree and the walk refuses it. Some targets vend their own
/// application element as a child of itself, and following that spends the
/// depth ceiling on copies of the same element while its siblings are re-walked
/// at every level, which can consume the node budget before later windows are
/// reached. `AXTreeBuilder` also guards this by element identity, which is the
/// stronger rule where it applies; this one holds whether or not the nested
/// element compares equal to its ancestor.
///
/// Shared by the dump and the input driver, so a dump does not carry the Apple
/// menu's contents, a press cannot match the menu or anything inside it, and
/// neither walk burns its depth on a self-nesting target. One implementation
/// rather than two, because the rules only hold if both walks apply them.
enum AXTraversalPolicy {
    /// Role of a top-level item in an application's menu bar.
    static let menuBarItemRole = "AXMenuBarItem"

    /// Role of an application's own accessibility element.
    static let applicationRole = "AXApplication"

    /// Whether a walk should enter `role`, sitting at `siblingIndex` among its
    /// parent's children.
    ///
    /// A leading child whose role would not read is refused. The rule cannot
    /// tell whether it is the Apple menu, and the two mistakes do not cost the
    /// same: refusing omits that node's descendants from a dump and puts the
    /// subtree beyond the input driver's search, while admitting it puts
    /// system actions such as Sleep and Log Out within reach of a press.
    ///
    /// A nested application is refused wherever it sits, not only in the
    /// leading position. The caller never offers the root here, so any
    /// `AXApplication` this sees already has one above it.
    static func shouldEnter(role: String?, siblingIndex: Int) -> Bool {
        if role == applicationRole { return false }
        guard siblingIndex == 0 else { return true }
        guard let role else { return false }
        return role != menuBarItemRole
    }
}
