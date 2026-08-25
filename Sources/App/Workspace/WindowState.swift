// SPDX-License-Identifier: GPL-3.0-or-later

import Observation

/// One open window: a stable id + its tab list (a reference, so the
/// owning TabStripViewController observes tab changes without the workspace's
/// `windows` array churning).
struct WindowState: Identifiable {
    let id: WindowID
    let tabs: TabListViewModel
}
