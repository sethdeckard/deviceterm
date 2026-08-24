// SPDX-License-Identifier: GPL-3.0-or-later
//
/// A route the device walks: an ordered list of waypoints, the speed it
/// travels between them, and how often it publishes a position along the
/// way.
///
/// This is what a `.gpx` file becomes. The GUI parses the file and sends
/// waypoints; the daemon never reads a user's path, so it needs neither a
/// GPX parser nor the GUI's file-access posture. Same split as Use My
/// Location, where the GUI resolves CoreLocation and the wire carries
/// plain numbers.
///
/// It carries the three things both backends need: a cadence, a speed,
/// and the points. Each wants them arranged differently, so neither
/// arrangement is used here. `devicectl` flattens the cadence into a
/// `"mode"` string plus a sibling field, and CoreSimulator vends a
/// separate selector per cadence; an enum instead makes "distance *and*
/// interval" unrepresentable rather than a rule someone has to know.
/// `DeviceCtlRouteFile` and `SimRouteCall` are the two translations.
///
/// `Codable` via Swift's automatic synthesis. `mode` external-tags like
/// the enums elsewhere in this module:
///
///   `{"mode":{"interval":{"seconds":1}},"speed":20,"waypoints":[…]}`
///
/// A golden test pins those bytes.
public struct RouteSpec: Equatable, Hashable, Sendable, Codable {
    /// How often the device publishes a position while travelling.
    ///
    /// An enum because a route has exactly one cadence, and neither
    /// backend takes two: CoreSimulator vends a separate selector per
    /// cadence, and `devicectl` reads a `"mode"` string plus the field
    /// that matches it. Modelling it this way makes "distance *and*
    /// interval" unrepresentable here instead of a rule someone has to
    /// remember at each call site.
    public enum Mode: Equatable, Hashable, Sendable, Codable {
        /// Publish after every `meters` travelled, regardless of how
        /// long that took.
        case distance(meters: Double)
        /// Publish every `seconds`, regardless of how far that moved.
        case interval(seconds: Double)
    }

    /// Speed to use when a route's own pace can't be derived, in metres
    /// per second.
    public static let defaultSpeed: Double = 20

    /// Cadence to use when building a route that names none, in seconds.
    ///
    /// Both defaults are simctl's own, read out of the binary rather
    /// than invented, so a route deviceterm plays moves the way the
    /// same waypoints would under `simctl location … start`.
    public static let defaultInterval: Double = 1

    /// Fewest waypoints that describe a route.
    ///
    /// One waypoint is a fixed position, so `GPXRouteMapper` maps that
    /// to `.coordinate` rather than sending a one-point route. simctl
    /// rejects fewer than two outright ("Must specify at least two
    /// waypoints"), so this is the underlying tools' floor as much as
    /// ours.
    public static let minimumWaypoints = 2

    /// Most waypoints one route may carry.
    ///
    /// A marathon or long-drive GPX can hold tens of thousands of
    /// points, and 10k of them encode to roughly half a megabyte, well
    /// under the wire's 16 MiB frame cap
    /// (`RPCFraming.defaultPayloadCap`). So this is not a transport
    /// limit: it is the point at which deviceterm stops and names the
    /// problem, rather than quietly accepting a file far larger than
    /// anyone meant to play.
    public static let maximumWaypoints = 10_000

    public var mode: Mode
    /// Metres per second the device travels between waypoints.
    ///
    /// **One scalar for the whole route**, which is a real limitation
    /// and not an oversight: neither backend accepts a per-leg speed. A
    /// GPX carrying `<time>` stamps therefore replays at its average
    /// pace, not its actual one. `GPXRouteMapper` derives the average;
    /// this type just carries it.
    public var speed: Double
    public var waypoints: [RouteWaypoint]

    /// Why this route can't be played, or `nil` when it is well-formed.
    ///
    /// Checked before the value reaches a backend, so bad input surfaces
    /// as `invalidParams` rather than an opaque bridge or subprocess
    /// error. Every rule here is one the tools underneath would
    /// otherwise enforce badly or not at all: CoreSimulator's selectors
    /// take a bare `NSArray` with no validation behind them.
    ///
    /// `NaN` fails the `> 0` test, since no comparison with it is true;
    /// an infinity passes that and is caught by the explicit `isFinite`
    /// check beside it. Both arms are needed.
    public var defect: SimulatedLocationDefect? {
        guard waypoints.count >= Self.minimumWaypoints else {
            return .tooFewWaypoints(count: waypoints.count)
        }
        guard waypoints.count <= Self.maximumWaypoints else {
            return .tooManyWaypoints(count: waypoints.count, limit: Self.maximumWaypoints)
        }
        guard speed > 0, speed.isFinite else { return .invalidRouteSpeed(speed) }
        switch mode {
        case let .distance(meters):
            guard meters > 0, meters.isFinite else { return .invalidRouteDistance(meters) }

        case let .interval(seconds):
            guard seconds > 0, seconds.isFinite else { return .invalidRouteInterval(seconds) }
        }
        for (index, waypoint) in waypoints.enumerated() where !waypoint.isValid {
            return .routeWaypointOutOfRange(
                index: index,
                latitude: waypoint.latitude,
                longitude: waypoint.longitude
            )
        }
        return nil
    }

    public init(mode: Mode, speed: Double, waypoints: [RouteWaypoint]) {
        self.mode = mode
        self.speed = speed
        self.waypoints = waypoints
    }
}
