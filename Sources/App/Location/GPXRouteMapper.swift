// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// GPX points to a location the device can take.
///
/// Pure and total. Every rule that decides *what a file means* lives
/// here, separately from the parser (which decides what the bytes say)
/// and from the loader (which decides how to read them).
///
/// **A one-point file is a position, not a route.** Xcode's own GPX
/// templates use a single `<wpt>` to mean "the device is here", and both
/// backends reject a route with fewer than two points, so collapsing it
/// is the only reading that works.
///
/// **Nothing throws.** Every document maps: one point becomes a
/// coordinate, any other count becomes a route, and `RouteSpec.defect` is
/// what then says whether that route is usable. That keeps one validation
/// vocabulary for the GUI and the daemon: the same sentence the daemon
/// would return as `invalidParams` is the one the alert shows, and there
/// is no second set of rules here to drift out of agreement with it. In
/// production the parser has already rejected a file with no points at
/// all (`GPXParseError.noPoints`), so the empty case is a property of
/// this function rather than a path a file takes.
enum GPXRouteMapper {
    /// Mean Earth radius in metres (IUGG). Distances here only ever
    /// divide into a duration to produce an average pace, so a spherical
    /// model is far more precision than the result carries.
    static let earthRadius: Double = 6_371_008.8

    /// What applying this file should set on the device.
    static func location(for document: GPXDocument) -> SimulatedLocation {
        if document.points.count == 1, let only = document.points.first {
            // Canonicalized to the saved file's precision, like every
            // other coordinate that reaches the daemon, so the menu's
            // exact-equality match can still recognize the position. A
            // route's waypoints deliberately are not: they are never
            // matched against a row, and rounding thousands of points
            // would move the path for no gain.
            return .coordinate(
                latitude: LocationsFileParser.canonical(only.latitude),
                longitude: LocationsFileParser.canonical(only.longitude)
            )
        }
        return .route(spec: RouteSpec(
            // Interval rather than distance, at simctl's own default
            // cadence. A time-based cadence publishes at a steady rate
            // whatever the pace, which is what a caller watching a
            // device move expects; a distance cadence goes silent when
            // the route slows down.
            mode: .interval(seconds: RouteSpec.defaultInterval),
            speed: speed(for: document),
            waypoints: document.points.map {
                RouteWaypoint(latitude: $0.latitude, longitude: $0.longitude)
            }
        ))
    }

    /// Metres per second to walk this route.
    ///
    /// Derived from the file when every point is timestamped: total
    /// distance over total elapsed time. **This is lossy, and
    /// unavoidably so.** A GPX records a time per point, so the real
    /// journey speeds up and slows down, while both backends accept a
    /// single scalar speed for the whole route. A recorded run therefore
    /// replays with the same start, finish, and duration, and none of
    /// its pacing. Documented in `docs/USAGE.md` rather than silently
    /// misrepresented.
    ///
    /// Anything that makes the average meaningless (an untimed or
    /// partly-timed file, points sharing one timestamp, a route of zero
    /// length) falls back to simctl's documented 20 m/s.
    static func speed(for document: GPXDocument) -> Double {
        guard document.isFullyTimed,
            let start = document.points.first?.time,
            let end = document.points.last?.time else {
            return RouteSpec.defaultSpeed
        }
        let duration = end.timeIntervalSince(start)
        let distance = length(of: document.points)
        guard duration > 0, distance > 0 else { return RouteSpec.defaultSpeed }
        return distance / duration
    }

    /// Total metres walked visiting every point in order.
    static func length(of points: [GPXWaypoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + metres(from: $1.0, to: $1.1) }
    }

    /// Great-circle distance between two points, in metres.
    ///
    /// The haversine form, which stays accurate for the short legs a GPX
    /// is made of; the plain spherical law of cosines loses precision
    /// exactly there.
    static func metres(from start: GPXWaypoint, to end: GPXWaypoint) -> Double {
        let radians = Double.pi / 180
        let lat1 = start.latitude * radians
        let lat2 = end.latitude * radians
        let deltaLat = (end.latitude - start.latitude) * radians
        let deltaLon = (end.longitude - start.longitude) * radians
        let haversine = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return 2 * earthRadius * asin(min(1, sqrt(haversine)))
    }
}
