// SPDX-License-Identifier: GPL-3.0-or-later
//
/// A simulated GPS position for one pane's device: the *value* of a
/// single device property, not several separate operations. Coordinate,
/// scenario, route, and cleared are the things that property can be, so
/// `pane.location.set` takes one of these rather than splitting into
/// set/scenario/route/clear methods. The menu that drives it is a radio
/// group over this type.
///
/// A route is a value here for the same reason a scenario is: both play
/// over time, and the device is at exactly one of them. The difference
/// is only who supplies the waypoints, Apple's built-in trips or the
/// user's own `.gpx`.
///
/// `cleared` rather than `none` so the case never reads as
/// `Optional.none` at a call site. It matches both backends' vocabulary:
/// CoreSimulator's `clearSimulatedLocationWithError:` and
/// `devicectl device simulate location clear`.
///
/// No label travels on the wire. The GUI derives display text from the
/// location value, so the daemon stores no user-authored strings.
///
/// `Codable` via Swift's automatic external-tagging synthesis, matching
/// the `PaneTarget` / `PaneSlot` precedent:
///
///   - `.cleared`                         → `{"cleared":{}}`
///   - `.coordinate(latitude:longitude:)` → `{"coordinate":{"latitude":37.3,"longitude":-122}}`
///   - `.scenario(name:)`                 → `{"scenario":{"name":"City Run"}}`
///   - `.route(spec:)`                    → `{"route":{"spec":{…}}}`
///
/// A golden test pins those exact bytes so a future change to
/// the synthesis can't drift the wire silently. `route` carries a
/// *labelled* payload for that reason: an unlabelled one would encode
/// under Swift's synthesized `_0` key, putting a compiler-internal name
/// on the wire.
public enum SimulatedLocation: Equatable, Hashable, Sendable, Codable {
    case cleared
    case coordinate(latitude: Double, longitude: Double)
    case scenario(name: String)
    case route(spec: RouteSpec)

    /// Accepted latitude, in degrees.
    public static let latitudeRange: ClosedRange<Double> = -90...90
    /// Accepted longitude, in degrees.
    public static let longitudeRange: ClosedRange<Double> = -180...180

    /// Why this value can't be applied to a device, or `nil` when it is
    /// well-formed.
    ///
    /// Checked before the value reaches a backend so bad input surfaces
    /// as `invalidParams` rather than as an opaque bridge or subprocess
    /// error. `NaN` and the infinities fail the range tests (a
    /// `ClosedRange` contains neither), so they need no separate arm.
    ///
    /// A scenario *name* is checked here only for being empty. Whether
    /// it is one the device offers is a per-device runtime question, so
    /// that half is the backend's job, not this type's.
    public var defect: SimulatedLocationDefect? {
        switch self {
        case .cleared:
            return nil

        case let .coordinate(latitude, longitude):
            guard Self.latitudeRange.contains(latitude) else {
                return .latitudeOutOfRange(latitude)
            }
            guard Self.longitudeRange.contains(longitude) else {
                return .longitudeOutOfRange(longitude)
            }
            return nil

        case let .scenario(name):
            return name.isEmpty ? .emptyScenarioName : nil

        case let .route(spec):
            return spec.defect
        }
    }
}

/// Why a `SimulatedLocation` is not applicable. Lives here rather than
/// in its own file because it has no meaning apart from the type it
/// describes.
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
