// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// SimRouteCallTests: the wire-to-CoreSimulator translation.
//
// Nothing else can catch a mistake here. `SimDeviceBackend` can't be
// constructed without a real sim, the selector takes a bare `NSArray`
// and answers with a plain `BOOL`, and a latitude/longitude pair in the
// wrong order is still a perfectly valid call: the device just walks
// somewhere else. Keeping the translation a pure value is what makes
// the ordering assertable at all.

private func route(
    mode: RouteSpec.Mode = .interval(seconds: 1),
    speed: Double = 20,
    points: [(Double, Double)] = [(1, 2), (3, 4)]
) -> RouteSpec {
    RouteSpec(
        mode: mode,
        speed: speed,
        waypoints: points.map { RouteWaypoint(latitude: $0.0, longitude: $0.1) }
    )
}

/// Flat and alternating, latitude first. Four values are two waypoints.
@Test("waypoints flatten to alternating latitude and longitude")
func waypointsFlattenLatitudeFirst() {
    let call = SimRouteCall(route(points: [(1, 2), (3, 4), (5, 6)]))
    #expect(call.waypoints.map(\.doubleValue) == [1, 2, 3, 4, 5, 6])
}

/// The count relationship the selector itself relies on: `simctl`
/// reports `count / 2` as the waypoint total.
@Test("the flat array is twice the waypoint count")
func flatArrayIsTwiceTheWaypointCount() {
    let spec = route(points: Array(repeating: (1.0, 2.0), count: 7))
    #expect(SimRouteCall(spec).waypoints.count == 14)
}

/// The two cadences are separate selectors, so this picks which one to
/// call rather than filling in a parameter.
@Test("each mode maps to its own selector's scalar", arguments: [
    (RouteSpec.Mode.interval(seconds: 2.5), SimRouteCall.Cadence.interval(2.5)),
    (.distance(meters: 100), .distance(100))
])
func modeMapsToCadence(mode: RouteSpec.Mode, expected: SimRouteCall.Cadence) {
    #expect(SimRouteCall(route(mode: mode)).cadence == expected)
}

@Test("speed is carried through unchanged")
func speedIsCarriedThrough() {
    #expect(SimRouteCall(route(speed: 3.75)).speed == 3.75)
}

/// Negative and fractional coordinates survive the boxing intact, which
/// is the half of the round trip `NSNumber` could quietly lose.
@Test("coordinate values survive boxing")
func coordinateValuesSurviveBoxing() {
    let call = SimRouteCall(route(points: [(-33.8688, 151.2093), (37.7749, -122.4194)]))
    #expect(call.waypoints.map(\.doubleValue) == [-33.8688, 151.2093, 37.7749, -122.4194])
}
