// SPDX-License-Identifier: GPL-3.0-or-later

/// Why a `SimulatedLocation` is not applicable. Has no meaning apart from
/// the type it describes.
public enum SimulatedLocationDefect: Equatable, Sendable {
    case latitudeOutOfRange(Double)
    case longitudeOutOfRange(Double)
    case emptyScenarioName
    /// A route with too few points to describe travel.
    case tooFewWaypoints(count: Int)
    /// A route longer than `RouteSpec.maximumWaypoints`.
    case tooManyWaypoints(count: Int, limit: Int)
    case invalidRouteSpeed(Double)
    case invalidRouteDistance(Double)
    case invalidRouteInterval(Double)
    /// A route waypoint that isn't a position on Earth. Carries the
    /// index because a route is a list: "latitude out of range" alone
    /// leaves the user to find which of several thousand points is
    /// wrong.
    case routeWaypointOutOfRange(index: Int, latitude: Double, longitude: Double)

    /// Wording for the `invalidParams` message the RPC layer returns.
    public var message: String {
        switch self {
        case let .latitudeOutOfRange(value):
            return "latitude must be between -90 and 90, got \(value)"

        case let .longitudeOutOfRange(value):
            return "longitude must be between -180 and 180, got \(value)"

        case .emptyScenarioName:
            return "scenario name must not be empty"

        case let .tooFewWaypoints(count):
            return "a route needs at least \(RouteSpec.minimumWaypoints) waypoints, got \(count)"

        case let .tooManyWaypoints(count, limit):
            return "a route may carry at most \(limit) waypoints, got \(count)"

        case let .invalidRouteSpeed(value):
            return "route speed must be a positive number of metres per second, got \(value)"

        case let .invalidRouteDistance(value):
            return "route update distance must be a positive number of metres, got \(value)"

        case let .invalidRouteInterval(value):
            return "route update interval must be a positive number of seconds, got \(value)"

        case let .routeWaypointOutOfRange(index, latitude, longitude):
            return "route waypoint \(index) is not a position on Earth "
                + "(latitude \(latitude), longitude \(longitude))"
        }
    }
}
