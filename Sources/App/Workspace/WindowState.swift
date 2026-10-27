// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Observation

/// One open window: a stable id + its tab list (a reference, so the
/// owning TabStripViewController observes tab changes without the workspace's
/// `windows` array churning).
struct WindowState: Identifiable {
    let id: WindowID
    let publicID: UUID
    var name: String?
    let tabs: TabListViewModel
    /// The frame a window restored from the saved layout opens at, read
    /// once when its controller is built. Nil opens it at the default size,
    /// centered.
    let restoredFrame: CGRect?

    init(
        id: WindowID,
        tabs: TabListViewModel,
        publicID: UUID = UUID(),
        name: String? = nil,
        restoredFrame: CGRect? = nil
    ) {
        self.id = id
        self.publicID = publicID
        self.name = name
        self.tabs = tabs
        self.restoredFrame = restoredFrame
    }
}
