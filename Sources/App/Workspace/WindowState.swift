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

    init(
        id: WindowID,
        tabs: TabListViewModel,
        publicID: UUID = UUID(),
        name: String? = nil
    ) {
        self.id = id
        self.publicID = publicID
        self.name = name
        self.tabs = tabs
    }
}
