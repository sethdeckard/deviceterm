// SPDX-License-Identifier: GPL-3.0-or-later
//
// LocationEntry: one line of the user's saved-locations file, parsed.
//
// An enum so parser results can distinguish entry kinds without changing
// the surrounding API. This version recognizes fixed points and paths to
// `.gpx` route files.
//
// Pure data with no formatting of its own. The menu decides how an
// unlabeled entry reads, so coordinate formatting and a route's fallback
// title stay in one place.

import DaemonProtocol

/// A location the user saved, in the order the file lists it.
enum LocationEntry: Equatable, Sendable {
    /// A fixed point, with the optional label its file line carried.
    case coordinate(latitude: Double, longitude: Double, label: String?)

    /// A `.gpx` file to walk, with the optional label its line carried.
    ///
    /// `path` is **already resolved**: `~` expanded and a relative path
    /// joined to the locations file's own directory, done at parse time
    /// because that is the last point where the file's location is
    /// known. Nothing downstream has to carry a base directory around,
    /// and the value is directly openable.
    ///
    /// Deliberately no waypoints here. Reading them means opening the
    /// file, and this type is built while a menu is being drawn.
    case route(path: String, label: String?)

    /// The name the user gave this entry, if any. A nil or empty label
    /// leaves the menu to render the entry itself.
    var label: String? {
        switch self {
        case let .coordinate(_, _, label), let .route(_, label):
            guard let label, !label.isEmpty else { return nil }
            return label
        }
    }
}
