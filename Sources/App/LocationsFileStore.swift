// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import os

/// Reads and writes the real file, opening it fresh on each call.
///
/// Statelessness is the point: a hand-edit is picked up with no cache to
/// invalidate, and several panes sharing one store can't disagree about
/// what the file says. Ordering comes from the shared gate, not from
/// holding state here.
///
/// Picked up is not the same as displayed. The menu draws from the view
/// model's snapshot and starts its read afterwards, so an edit made just
/// before an open shows up on the following one. See
/// `PaneLocationViewModel.savedLocations`.
struct LocationsFileStore: LocationsStoring {
    var path: String = LocationsFile.defaultPath

    func load() async -> [LocationEntry] {
        await LocationsFileGate.shared.load(path: path)
    }

    func record(_ entry: LocationEntry) async {
        await LocationsFileGate.shared.record(entry, path: path)
    }
}
