// SPDX-License-Identifier: GPL-3.0-or-later
//
// TabMarkerDecision: which markers a tab's pill carries, and in what order.
//
// The strip has two markers and neither excludes the other: an automation tab
// can be protected, and both then show. Their order is what keeps a strip
// readable at a glance, so it is stated once here and pinned by a test rather
// than left to whatever order the strip's rendering code mounts them in.

import DaemonProtocol

enum TabMarkerDecision {
    /// The ordered markers for a tab.
    ///
    /// Protection sits closer to the title because it is the one that comes
    /// and goes. A tab's role is fixed for its life, so keeping the mutable
    /// marker on the inside means a protection toggle never shifts the wand.
    ///
    /// `isEffectivelyProtected` rather than `isProtected`: the marker follows
    /// whether the tab is hidden *now*, which flips before the daemon confirms
    /// and stays set through a failed unprotect. That is the fail-closed axis
    /// `TabState` names as the one driving tab chrome.
    static func markers(
        role: SessionRole,
        isEffectivelyProtected: Bool
    ) -> [TabPillMarker] {
        var markers: [TabPillMarker] = []
        if role == .automation { markers.append(.automation) }
        if isEffectivelyProtected { markers.append(.protection) }
        return markers
    }
}
