// SPDX-License-Identifier: GPL-3.0-or-later

/// One point on a route. Has no meaning apart from the `RouteSpec` that
/// carries it.
public struct RouteWaypoint: Equatable, Hashable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double

    /// Whether this point is a position on Earth. Ranges come from
    /// `SimulatedLocation`, so a waypoint and a fixed coordinate are
    /// held to one rule rather than two that could drift.
    public var isValid: Bool {
        SimulatedLocation.latitudeRange.contains(latitude)
            && SimulatedLocation.longitudeRange.contains(longitude)
    }

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}
