// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import Testing

// GPXRouteMapperTests: what a file *means*, as distinct from what it
// says.
//
// Two rules carry the weight. A one-point file is a position, not a
// one-point route, because both backends reject a route shorter than two
// points and Xcode's own templates use a single `<wpt>` to mean "the
// device is here". And every way of making an average pace meaningless
// falls back to simctl's documented 20 m/s rather than to zero, which
// would leave a device parked on the start line.

private func fixture(_ name: String) throws -> GPXDocument {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "gpx"),
        "missing fixture \(name).gpx"
    )
    return try GPXDocument.parse(Data(contentsOf: url))
}

private func point(_ latitude: Double, _ longitude: Double, at seconds: Double? = nil) -> GPXWaypoint {
    GPXWaypoint(
        latitude: latitude,
        longitude: longitude,
        name: nil,
        time: seconds.map { Date(timeIntervalSince1970: $0) }
    )
}

private func spec(of location: SimulatedLocation) throws -> RouteSpec {
    guard case let .route(spec) = location else {
        throw MapperTestFailure.notARoute(location)
    }
    return spec
}

private enum MapperTestFailure: Error {
    case notARoute(SimulatedLocation)
}

// MARK: - Shape

@Test("a one-point file is a coordinate, not a route")
func singlePointCollapsesToCoordinate() throws {
    let location = GPXRouteMapper.location(for: try fixture("gpx-single-wpt"))
    #expect(location == .coordinate(latitude: 37.7749, longitude: -122.4194))
}

/// Canonicalized on the way out, like every other coordinate that
/// reaches the daemon, so the menu's exact-equality match can still
/// recognize a saved row at the same place.
@Test("a one-point file is canonicalized to the file's precision")
func singlePointIsCanonicalized() {
    let document = GPXDocument(points: [point(37.77490001, -122.41940001)])
    #expect(
        GPXRouteMapper.location(for: document)
            == .coordinate(
                latitude: LocationsFileParser.canonical(37.77490001),
                longitude: LocationsFileParser.canonical(-122.41940001)
            )
    )
}

@Test("a multi-point file becomes a route in interval mode")
func multiPointBecomesRoute() throws {
    let route = try spec(of: GPXRouteMapper.location(for: try fixture("gpx-track-untimed")))
    #expect(route.mode == .interval(seconds: RouteSpec.defaultInterval))
    #expect(route.waypoints.count == 3)
    #expect(route.waypoints.map(\.longitude) == [0.0, 0.001, 0.002])
}

/// Route waypoints deliberately keep full precision: they are never
/// matched against a saved row, and rounding thousands of points would
/// move the path for nothing.
@Test("route waypoints are not rounded")
func routeWaypointsKeepPrecision() throws {
    let document = GPXDocument(points: [
        point(37.77490001, -122.41940001),
        point(37.77590001, -122.41840001)
    ])
    let route = try spec(of: GPXRouteMapper.location(for: document))
    #expect(route.waypoints.first?.latitude == 37.77490001)
}

/// Total by construction: an empty document maps to a route whose own
/// `defect` explains itself, so there is no second failure vocabulary
/// here to drift from the daemon's.
@Test("an empty document maps to a route that reports its own defect")
func emptyDocumentIsSelfDescribing() {
    let location = GPXRouteMapper.location(for: GPXDocument(points: []))
    #expect(location.defect == .tooFewWaypoints(count: 0))
}

// MARK: - Speed

/// Three points 0.001 degrees apart on the equator, 10 seconds between
/// each: about 111.19 m per leg, 222.39 m over 20 s.
@Test("a fully timed file derives its average pace")
func timedFileDerivesSpeed() throws {
    let route = try spec(of: GPXRouteMapper.location(for: try fixture("gpx-track-timed")))
    #expect(abs(route.speed - 11.12) < 0.05, "got \(route.speed)")
}

@Test("an untimed file falls back to the documented default")
func untimedFileUsesDefaultSpeed() throws {
    let route = try spec(of: GPXRouteMapper.location(for: try fixture("gpx-track-untimed")))
    #expect(route.speed == RouteSpec.defaultSpeed)
}

/// A partly-timed file has no defensible average: the untimed legs
/// contribute distance but no duration, so dividing one by the other
/// would invent a pace faster than the recording.
@Test("a partly timed file falls back to the documented default")
func partlyTimedFileUsesDefaultSpeed() throws {
    let route = try spec(of: GPXRouteMapper.location(for: try fixture("gpx-track-partly-timed")))
    #expect(route.speed == RouteSpec.defaultSpeed)
}

/// Both would otherwise divide by zero or produce zero, and a route at
/// 0 m/s never leaves the start line.
@Test("a degenerate timing or path falls back to the default", arguments: [
    // Every point at the same instant: no elapsed time.
    [point(0, 0, at: 5), point(0, 0.001, at: 5)],
    // Every point at the same place: no distance.
    [point(0, 0, at: 0), point(0, 0, at: 10)]
])
func degenerateInputsUseDefaultSpeed(points: [GPXWaypoint]) {
    #expect(GPXRouteMapper.speed(for: GPXDocument(points: points)) == RouteSpec.defaultSpeed)
}

/// Both backends take one scalar speed for the whole route, so a sprint
/// followed by a walk replays at the average of the two.
@Test("a route with varying pace replays at its average")
func varyingPaceCollapsesToAnAverage() throws {
    // 1 degree of latitude in 10 s, then another in 90 s.
    let document = GPXDocument(points: [
        point(0, 0, at: 0),
        point(1, 0, at: 10),
        point(2, 0, at: 100)
    ])
    let route = try spec(of: GPXRouteMapper.location(for: document))
    let expected = GPXRouteMapper.length(of: document.points) / 100
    #expect(abs(route.speed - expected) < 0.001)
}

// MARK: - Distance

/// A known long-haul pair, so the haversine implementation is pinned
/// against a figure that can be checked against any mapping tool rather
/// than against itself.
@Test("great-circle distance matches a known pair")
func distanceMatchesKnownPair() {
    let metres = GPXRouteMapper.metres(
        from: point(37.7749, -122.4194),
        to: point(40.7128, -74.0060)
    )
    #expect(abs(metres - 4_129_000) < 5_000, "got \(metres)")
}

@Test("distance is zero between identical points")
func distanceIsZeroForIdenticalPoints() {
    #expect(GPXRouteMapper.metres(from: point(51.5, -0.12), to: point(51.5, -0.12)) == 0)
}

@Test("route length is the sum of its legs")
func lengthSumsItsLegs() {
    let points = [point(0, 0), point(0, 1), point(0, 2)]
    let legs = GPXRouteMapper.metres(from: points[0], to: points[1])
        + GPXRouteMapper.metres(from: points[1], to: points[2])
    #expect(abs(GPXRouteMapper.length(of: points) - legs) < 0.001)
}
