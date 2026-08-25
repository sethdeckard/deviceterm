// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One position from a GPX file, with whatever optional detail the file
/// carried for it.
struct GPXWaypoint: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    /// The point's `<name>`, if it had one.
    var name: String?
    /// The point's `<time>`, if it had one and it parsed. Used only to
    /// derive an average pace; see `GPXRouteMapper`.
    var time: Date?
}
