// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// One row of the Location submenu.
enum LocationMenuRow: Equatable, Sendable {
    case separator
    /// A non-selectable section label.
    case header(title: String)
    /// A selectable location. Choosing the row applies `location`.
    case location(title: String, location: SimulatedLocation, isActive: Bool)
    /// A saved `.gpx` route. Carries the file path rather than a
    /// `SimulatedLocation`, because the waypoints are in the file and
    /// reading it is I/O this row is built without doing. Choosing the
    /// row is what opens it.
    case route(title: String, path: String, isActive: Bool)
    /// Applies this Mac's own position. Which position that is isn't
    /// known until the row is chosen, so like `customCoordinates` it
    /// carries no `SimulatedLocation` and is never checked: the
    /// coordinate it produces gets its own row once the daemon records
    /// it.
    case useMyLocation
    /// Opens the Custom Coordinates sheet. Applies nothing by itself,
    /// so it carries no `SimulatedLocation` and is never checked.
    case customCoordinates
}
