// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import os

/// The saved-locations file as its one consumer uses it, so
/// `PaneLocationViewModel` can be tested without touching a real path.
///
/// `record` answers nothing. The caller re-reads through `load()`
/// instead, because that is the view model's single fenced publication
/// path; handing back a list here would invite a second one, and two
/// publishers can resume out of order and revert the menu to a snapshot
/// older than the file.
protocol LocationsStoring: Sendable {
    /// Every saved location, in file order. Empty when nothing is saved
    /// *or* when the file can't be read. The menu has to render either
    /// way, so the distinction is logged rather than thrown.
    func load() async -> [LocationEntry]
    /// Save a location the user just applied, if it isn't already listed.
    func record(_ entry: LocationEntry) async
}
