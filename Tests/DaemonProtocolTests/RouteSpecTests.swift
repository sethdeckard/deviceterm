// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

// RouteSpecTests: the wire bytes and the validation rule.
//
// The encoding is Swift's automatic synthesis, so these golden strings
// are the only thing between a compiler change and a silent wire break.
// Same reasoning as `SimulatedLocationTests` and `PaneTargetTests`.
//
// The validation half matters more than it looks. CoreSimulator's route
// selectors take a bare `NSArray` and validate nothing behind it, so
// every rule a caller might expect the platform to enforce is enforced
// here instead.

private let twoPoints = [
    RouteWaypoint(latitude: 37.3349, longitude: -122.009),
    RouteWaypoint(latitude: 37.3359, longitude: -122.008)
]

private func encode(_ value: some Encodable) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(bytes: try encoder.encode(value), encoding: .utf8) ?? ""
}

private func route(
    mode: RouteSpec.Mode = .interval(seconds: 1),
    speed: Double = 20,
    waypoints: [RouteWaypoint] = twoPoints
) -> RouteSpec {
    RouteSpec(mode: mode, speed: speed, waypoints: waypoints)
}

// MARK: - Wire

@Test("RouteSpec.Mode encodes to the pinned wire bytes", arguments: [
    (RouteSpec.Mode.interval(seconds: 1), #"{"interval":{"seconds":1}}"#),
    (.distance(meters: 100), #"{"distance":{"meters":100}}"#)
])
func routeModeWireBytes(mode: RouteSpec.Mode, expected: String) throws {
    #expect(try encode(mode) == expected)
}

@Test("RouteSpec encodes to the pinned wire bytes")
func routeSpecWireBytes() throws {
    let expected = #"{"mode":{"interval":{"seconds":1}},"speed":20,"#
        + #""waypoints":[{"latitude":37.3349,"longitude":-122.009},"#
        + #"{"latitude":37.3359,"longitude":-122.008}]}"#
    #expect(try encode(route()) == expected)
}

@Test("RouteSpec round-trips", arguments: [
    route(),
    route(mode: .distance(meters: 250), speed: 3.5),
    route(waypoints: (0..<50).map { RouteWaypoint(latitude: Double($0) / 10, longitude: 0) })
])
func routeSpecRoundTrips(spec: RouteSpec) throws {
    let data = try JSONEncoder().encode(spec)
    #expect(try JSONDecoder().decode(RouteSpec.self, from: data) == spec)
}

// MARK: - Validation

@Test("a well-formed route reports no defect", arguments: [
    route(),
    route(mode: .distance(meters: 0.5), speed: 0.1),
    route(waypoints: Array(repeating: twoPoints[0], count: RouteSpec.maximumWaypoints))
])
func wellFormedRoutesHaveNoDefect(spec: RouteSpec) {
    #expect(spec.defect == nil)
}

/// One point is a position, not a route, and the mapper collapses it to
/// `.coordinate` before it ever gets here. simctl rejects fewer than two
/// itself, so this is the tools' own floor.
@Test("a route shorter than two points is rejected", arguments: [0, 1])
func shortRoutesAreRejected(count: Int) {
    let spec = route(waypoints: Array(twoPoints.prefix(count)))
    #expect(spec.defect == .tooFewWaypoints(count: count))
}

@Test("a route longer than the cap is rejected")
func longRoutesAreRejected() {
    let count = RouteSpec.maximumWaypoints + 1
    let spec = route(waypoints: Array(repeating: twoPoints[0], count: count))
    #expect(spec.defect == .tooManyWaypoints(count: count, limit: RouteSpec.maximumWaypoints))
}

/// `NaN` fails the `> 0` test, since no comparison with it is true; an
/// infinity passes that and is caught by `isFinite`. Both are pinned,
/// because each is rejected by a different half of the guard.
@Test("a non-positive or non-finite speed is rejected", arguments: [
    0.0, -1.0, Double.nan, Double.infinity
])
func badSpeedsAreRejected(speed: Double) {
    let defect = route(speed: speed).defect
    guard case let .invalidRouteSpeed(got) = defect else {
        Issue.record("expected invalidRouteSpeed, got \(String(describing: defect))")
        return
    }
    #expect(got == speed || (got.isNaN && speed.isNaN))
}

@Test("a non-positive cadence is rejected", arguments: [
    (RouteSpec.Mode.interval(seconds: 0), SimulatedLocationDefect.invalidRouteInterval(0)),
    (.interval(seconds: -2), .invalidRouteInterval(-2)),
    (.distance(meters: 0), .invalidRouteDistance(0)),
    (.distance(meters: -5), .invalidRouteDistance(-5))
])
func badCadencesAreRejected(mode: RouteSpec.Mode, expected: SimulatedLocationDefect) {
    #expect(route(mode: mode).defect == expected)
}

/// The index is the reason this is its own defect case rather than a
/// reused `latitudeOutOfRange`: a route is a list, and "latitude out of
/// range" alone leaves the user to find which of several thousand points
/// is wrong.
@Test("an off-globe waypoint is rejected and names its index")
func offGlobeWaypointIsRejected() {
    let spec = route(waypoints: [
        twoPoints[0],
        RouteWaypoint(latitude: 91, longitude: 0),
        twoPoints[1]
    ])
    #expect(spec.defect == .routeWaypointOutOfRange(index: 1, latitude: 91, longitude: 0))
    #expect(spec.defect?.message.contains("waypoint 1") == true)
}

/// Arity is checked before positions, so an empty route says "too few"
/// rather than reporting nothing at all.
@Test("count is checked before the waypoints themselves")
func countIsCheckedFirst() {
    let spec = route(waypoints: [RouteWaypoint(latitude: 91, longitude: 0)])
    #expect(spec.defect == .tooFewWaypoints(count: 1))
}

@Test("route defect messages name the problem", arguments: [
    (SimulatedLocationDefect.tooFewWaypoints(count: 1), "at least"),
    (.tooManyWaypoints(count: 20_000, limit: 10_000), "at most"),
    (.invalidRouteSpeed(0), "speed"),
    (.invalidRouteDistance(0), "metres"),
    (.invalidRouteInterval(0), "seconds"),
    (.routeWaypointOutOfRange(index: 3, latitude: 91, longitude: 0), "waypoint 3")
])
func routeDefectMessagesAreDescriptive(defect: SimulatedLocationDefect, needle: String) {
    #expect(defect.message.contains(needle))
}
