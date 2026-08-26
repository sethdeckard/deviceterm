// SPDX-License-Identifier: GPL-3.0-or-later

import Observation

/// The single "what's open" representation:
/// every window (each with its TabListViewModel) plus the selected
/// window. AppDelegate reconciles its WindowControllers to this.
/// Mutated by the Router and, for what the Router can't do itself (it
/// has no AppKit access), by the AppDelegate: the tab-transfer
/// coordinator calls `addWindow` for a tear-off window and `select` for
/// a cross-window move, and `windowDidBecomeKey` calls `select` to
/// mirror in whichever window AppKit made key. So the selection follows
/// AppKit for a plain focus change and is chosen outright by the
/// structural ones.
@MainActor
@Observable
final class WorkspaceViewModel {
    private(set) var windows: [WindowState] = []
    /// Selected window, nil when none are open.
    private(set) var selectedWindowID: WindowID?

    /// Append a window and make it the selected one.
    func addWindow(_ window: WindowState) {
        windows.append(window)
        selectedWindowID = window.id
    }

    func removeWindow(id: WindowID) {
        windows.removeAll { $0.id == id }
        if selectedWindowID == id { selectedWindowID = windows.last?.id }
    }

    func select(id: WindowID) {
        if windows.contains(where: { $0.id == id }) { selectedWindowID = id }
    }

    func window(id: WindowID) -> WindowState? { windows.first { $0.id == id } }

    /// The window whose tab list contains `tab`, for the tab/pane routes
    /// that name only a TabID.
    func windowContaining(tab id: TabID) -> WindowState? {
        windows.first { $0.tabs.tab(id: id) != nil }
    }
}
