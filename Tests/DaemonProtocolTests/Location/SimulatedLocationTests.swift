// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

// SimulatedLocationTests: the wire bytes and the validation rule.
//
// The encoding comes from Swift's automatic external-tagging synthesis
// rather than a hand-written `Codable`, so these golden strings are the
// only thing standing between a future compiler change and a silent
// wire break. Same reasoning as `PaneTargetTests`.

private func encode(_ location: SimulatedLocation) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(bytes: try encoder.encode(location), encoding: .utf8) ?? ""
}

private let shortRoute = RouteSpec(
    mode: .interval(seconds: 1),
    speed: 20,
    waypoints: [
        RouteWaypoint(latitude: 1, longitude: 2),
        RouteWaypoint(latitude: 3, longitude: 4)
    ]
)

private let shortRouteJSON = #"{"route":{"spec":{"mode":{"interval":{"seconds":1}},"#
    + #""speed":20,"waypoints":[{"latitude":1,"longitude":2},"#
    + #"{"latitude":3,"longitude":4}]}}}"#

/// `route` carries a *labelled* payload deliberately. An unlabelled
/// associated value would encode under Swift's synthesized `_0` key,
/// putting a compiler-internal name on the wire where a future synthesis
/// change could move it.
@Test("SimulatedLocation encodes to the pinned wire bytes", arguments: [
    (SimulatedLocation.cleared, #"{"cleared":{}}"#),
    (.coordinate(latitude: 37.3349, longitude: -122.009), #"{"coordinate":{"latitude":37.3349,"longitude":-122.009}}"#),
    (.scenario(name: "City Run"), #"{"scenario":{"name":"City Run"}}"#),
    (.route(spec: shortRoute), shortRouteJSON)
])
func simulatedLocationWireBytes(location: SimulatedLocation, expected: String) throws {
    #expect(try encode(location) == expected)
}

@Test("SimulatedLocation round-trips", arguments: [
    SimulatedLocation.cleared,
    .coordinate(latitude: -90, longitude: 180),
    .scenario(name: "Freeway Drive"),
    .route(spec: shortRoute)
])
func simulatedLocationRoundTrips(location: SimulatedLocation) throws {
    let data = try JSONEncoder().encode(location)
    #expect(try JSONDecoder().decode(SimulatedLocation.self, from: data) == location)
}

// MARK: - Validation

@Test("well-formed locations report no defect", arguments: [
    SimulatedLocation.cleared,
    .coordinate(latitude: 0, longitude: 0),
    .coordinate(latitude: 90, longitude: 180),
    .coordinate(latitude: -90, longitude: -180),
    .scenario(name: "City Run"),
    .route(spec: shortRoute)
])
func wellFormedLocationsHaveNoDefect(location: SimulatedLocation) {
    #expect(location.defect == nil)
}

/// `NaN` and the infinities are caught by the range tests rather than a
/// dedicated arm, since a `ClosedRange` contains none of them, so they
/// are pinned here to keep that implicit behavior from regressing.
@Test("out-of-range and non-finite coordinates are rejected", arguments: [
    (90.0001, 0.0, SimulatedLocationDefect.latitudeOutOfRange(90.0001)),
    (-90.0001, 0.0, .latitudeOutOfRange(-90.0001)),
    (0.0, 180.0001, .longitudeOutOfRange(180.0001)),
    (0.0, -180.0001, .longitudeOutOfRange(-180.0001)),
    (Double.nan, 0.0, .latitudeOutOfRange(Double.nan)),
    (0.0, Double.infinity, .longitudeOutOfRange(Double.infinity))
])
func badCoordinatesAreRejected(latitude: Double, longitude: Double, expected: SimulatedLocationDefect) {
    let defect = SimulatedLocation.coordinate(latitude: latitude, longitude: longitude).defect
    // `NaN != NaN`, so compare the case and its payload directly rather
    // than leaning on `Equatable` for the non-finite rows.
    switch (defect, expected) {
    case let (.latitudeOutOfRange(got), .latitudeOutOfRange(want)):
        #expect(got == want || (got.isNaN && want.isNaN))

    case let (.longitudeOutOfRange(got), .longitudeOutOfRange(want)):
        #expect(got == want || (got.isNaN && want.isNaN))

    default:
        Issue.record("expected \(expected), got \(String(describing: defect))")
    }
}

/// Latitude is checked first, so a doubly-bad pair names latitude. Pins
/// the order so the error message is deterministic.
@Test("a doubly-invalid coordinate reports latitude first")
func latitudeIsReportedFirst() {
    let defect = SimulatedLocation.coordinate(latitude: 200, longitude: 200).defect
    #expect(defect == .latitudeOutOfRange(200))
}

@Test("an empty scenario name is rejected")
func emptyScenarioNameIsRejected() {
    #expect(SimulatedLocation.scenario(name: "").defect == .emptyScenarioName)
}

/// This type does not know which scenario names are valid; the backend
/// checks them.
@Test("an unknown scenario name is not this type's business")
func unknownScenarioNameIsAccepted() {
    #expect(SimulatedLocation.scenario(name: "Not A Real Trip").defect == nil)
}

@Test("defect messages name the offending value", arguments: [
    (SimulatedLocationDefect.latitudeOutOfRange(91), "latitude"),
    (.longitudeOutOfRange(181), "longitude"),
    (.emptyScenarioName, "scenario name")
])
func defectMessagesAreDescriptive(defect: SimulatedLocationDefect, needle: String) {
    #expect(defect.message.contains(needle))
}

/// Delegated rather than reimplemented, so `pane.location.set` rejects a
/// bad route with the same sentence `RouteSpec` would give and there is
/// only one place the rule lives. `RouteSpecTests` covers the rules
/// themselves.
@Test("a route's defect is the route's own")
func routeDefectIsDelegated() {
    var spec = shortRoute
    spec.waypoints = [spec.waypoints[0]]
    #expect(SimulatedLocation.route(spec: spec).defect == spec.defect)
    #expect(spec.defect == .tooFewWaypoints(count: 1))
}
