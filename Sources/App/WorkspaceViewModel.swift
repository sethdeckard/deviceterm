// SPDX-License-Identifier: GPL-3.0-or-later
//
// WorkspaceViewModel: the single "what's open" representation:
// every window (each with its TabListViewModel) plus the selected
// window. AppDelegate reconciles its WindowControllers to this.
// Mutated by the Router and, for the GUI-only live-tab relocation the
// Router can't perform (it has no AppKit access), by the AppDelegate
// tab-transfer coordinator, which calls `addWindow` for a tear-off
// window after relocating the dragged tab's live view controller.

import Observation

/// One open window: a stable id + its tab list (a reference, so the
/// owning TabStripViewController observes tab changes without the workspace's
/// `windows` array churning).
struct WindowState: Identifiable {
    let id: WindowID
    let tabs: TabListViewModel
}

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
