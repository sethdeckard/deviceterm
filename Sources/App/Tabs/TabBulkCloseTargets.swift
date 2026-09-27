// SPDX-License-Identifier: GPL-3.0-or-later

/// The tabs the context menu's Close Other Tabs and Close Tabs to the Right
/// close.
///
/// Neither ever includes a pinned tab. A tab is pinned so that it stays, and
/// the tabs most often pinned host configured automation programs, which a
/// sweep of the strip should not take down. A pinned tab still closes when it
/// is the tab named: Close Tab, ⌥⌘W, or ⌘W on its last pane.
enum TabBulkCloseTargets {
    /// Every unpinned tab except `tabID`, in strip order. Empty when `tabID`
    /// is not in `tabs`.
    static func others(of tabID: TabID, in tabs: [TabState]) -> [TabID] {
        guard tabs.contains(where: { $0.id == tabID }) else { return [] }
        return tabs.filter { $0.id != tabID && !$0.isPinned }.map(\.id)
    }

    /// Every unpinned tab after `tabID`, in strip order. Empty when `tabID`
    /// is not in `tabs`.
    static func toTheRight(of tabID: TabID, in tabs: [TabState]) -> [TabID] {
        guard let pivot = tabs.firstIndex(where: { $0.id == tabID }) else { return [] }
        return tabs[(pivot + 1)...].filter { !$0.isPinned }.map(\.id)
    }
}
