// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

// LocationMenuModelTests: the submenu's shape, with no AppKit.
//
// The rules under test: empty sections are omitted rather than shown
// disabled; the device's scenario order and the file's saved order are
// each preserved verbatim; and a nil claim checks no rows, while a
// known claim checks one, including for a location the menu doesn't
// otherwise offer.

private func state(
    _ location: SimulatedLocation? = nil,
    scenarios: [String] = []
) -> PaneLocationStateResult {
    PaneLocationStateResult(location: location, scenarios: scenarios)
}

private func saved(_ latitude: Double, _ longitude: Double, _ label: String? = nil) -> LocationEntry {
    .coordinate(latitude: latitude, longitude: longitude, label: label)
}

private func titles(_ rows: [LocationMenuRow]) -> [String] {
    rows.compactMap { row in
        switch row {
        case .separator:
            return nil

        case let .header(title):
            return title

        case let .location(title, _, _):
            return title

        case let .route(title, _, _):
            return title

        case .useMyLocation:
            return LocationMenuModel.useMyLocationTitle

        case .customCoordinates:
            return LocationMenuModel.customTitle
        }
    }
}

/// Route rows count too: the one-checkmark invariant is across the whole
/// menu, so counting only `.location` rows would let a route quietly
/// take a second one.
private func activeTitles(_ rows: [LocationMenuRow]) -> [String] {
    rows.compactMap { row in
        switch row {
        case let .location(title, _, isActive), let .route(title, _, isActive):
            return isActive ? title : nil

        default:
            return nil
        }
    }
}

private func savedRoute(_ path: String, _ label: String? = nil) -> LocationEntry {
    .route(path: path, label: label)
}

/// A pane deviceterm has **explicitly cleared**, whose device offers no
/// scenarios. Two rules meet here: an empty scenario list omits the Trips
/// section rather than showing an empty disabled header, and `.cleared`
/// checks `None`. That is the one case where checking `None` is correct,
/// because deviceterm actually sent the clear.
///
/// Note this is *not* the cold-pane case: a device that isn't running
/// enumerates no scenarios, but its claim is `nil`, not `.cleared`
/// (`unknownClaimChecksNothing` covers that).
@Test("an explicitly cleared pane checks None and still offers both action rows")
func clearedPaneWithNoScenariosChecksNone() {
    let rows = LocationMenuModel.rows(for: state(.cleared))
    #expect(titles(rows) == [
        LocationMenuModel.clearedTitle,
        LocationMenuModel.useMyLocationTitle,
        LocationMenuModel.customTitle
    ])
    #expect(activeTitles(rows) == [LocationMenuModel.clearedTitle])
}

/// The genuine cold-pane shape: no claim *and* no scenarios, because the
/// device isn't running. Nothing is checked and there is no Trips
/// section, since an empty enumeration means no scenarios are available
/// rather than signalling an error. Use My Location and Custom
/// Coordinates are still offered, since neither reads a list: one asks
/// the Mac and the other asks the user, and typing a point is how the
/// saved list gets its first entry.
@Test("a cold pane offers unchecked None and both action rows")
func coldPaneOffersUncheckedNoneAndCustom() {
    let rows = LocationMenuModel.rows(for: state(nil, scenarios: []))
    #expect(titles(rows) == [
        LocationMenuModel.clearedTitle,
        LocationMenuModel.useMyLocationTitle,
        LocationMenuModel.customTitle
    ])
    #expect(activeTitles(rows).isEmpty)
}

/// The distinction the daemon's `nil` exists to preserve. `nil` means
/// deviceterm has no claim, not that the simulation was cleared. An
/// ownership transfer sends no clear, so `.cleared` cannot be inferred
/// from it, and checking `None` would assert something unknown.
@Test("an unknown claim checks nothing, not None")
func unknownClaimChecksNothing() {
    let rows = LocationMenuModel.rows(for: state(nil, scenarios: ["City Run"]))
    #expect(activeTitles(rows).isEmpty)
    // The rows are all still offered. The menu works; it just asserts
    // nothing about the device's current position.
    #expect(titles(rows) == [
        LocationMenuModel.clearedTitle,
        LocationMenuModel.useMyLocationTitle,
        LocationMenuModel.tripsHeader,
        "City Run",
        LocationMenuModel.customTitle
    ])
}

@Test("scenarios appear under a Trips header in device order")
func scenariosAppearUnderTrips() {
    let rows = LocationMenuModel.rows(
        for: state(scenarios: ["City Run", "City Bicycle Ride", "Apple", "Freeway Drive"])
    )
    #expect(titles(rows) == [
        LocationMenuModel.clearedTitle,
        LocationMenuModel.useMyLocationTitle,
        LocationMenuModel.tripsHeader,
        "City Run",
        "City Bicycle Ride",
        "Apple",
        "Freeway Drive",
        LocationMenuModel.customTitle
    ])
}

@Test("the header is not selectable")
func headerIsNotALocation() {
    let rows = LocationMenuModel.rows(for: state(scenarios: ["City Run"]))
    let headerIsALocation = rows.contains { row in
        guard case let .location(title, _, _) = row else { return false }
        return title == LocationMenuModel.tripsHeader
    }
    #expect(!headerIsALocation)
}

@Test("the active scenario is the only checked row")
func activeScenarioIsChecked() {
    let rows = LocationMenuModel.rows(
        for: state(.scenario(name: "Apple"), scenarios: ["City Run", "Apple"])
    )
    #expect(activeTitles(rows) == ["Apple"])
}

@Test("choosing a trip row sends that scenario")
func tripRowCarriesItsScenario() {
    let rows = LocationMenuModel.rows(for: state(scenarios: ["City Run"]))
    let payloads = rows.compactMap { row -> SimulatedLocation? in
        guard case let .location(_, location, _) = row else { return nil }
        return location
    }
    #expect(payloads == [.cleared, .scenario(name: "City Run")])
}

/// The rule that keeps a claim visible: a location with no row of its
/// own still gets one, so the menu never renders as "nothing set" while
/// the daemon still holds a location claim. A coordinate exercises this
/// path.
@Test("an active location with no row of its own still gets one")
func unlistedActiveLocationGetsARow() {
    let rows = LocationMenuModel.rows(
        for: state(.coordinate(latitude: 37.7749, longitude: -122.4194), scenarios: ["City Run"])
    )
    #expect(activeTitles(rows) == ["37.7749, -122.4194"])
    // `None` is present but unchecked, because a coordinate is set.
    #expect(!titles(rows).isEmpty)
}

/// A scenario the device stopped reporting (after rebooting into a
/// different runtime, say) is still the active claim, so it keeps its
/// checkmark rather than vanishing.
@Test("an active scenario missing from the device list is still shown")
func unlistedActiveScenarioGetsARow() {
    let rows = LocationMenuModel.rows(for: state(.scenario(name: "Gone"), scenarios: ["City Run"]))
    #expect(activeTitles(rows) == ["Gone"])
}

/// The model guarantees its own one-checkmark invariant rather than
/// relying on the backends to vend unique names. A scenario name is the
/// identifier `pane.location.set` consumes, so a device reporting one
/// twice is already an anomaly; nothing in the daemon rejects it, and
/// two checkmarks would be worse than a duplicated row.
@Test("a duplicated scenario name still checks only one row")
func duplicateScenarioNameChecksOneRow() {
    let rows = LocationMenuModel.rows(
        for: state(.scenario(name: "City Run"), scenarios: ["City Run", "City Run"])
    )
    #expect(activeTitles(rows) == ["City Run"])
    // Both rows are still offered; only the checkmark is deduplicated.
    #expect(titles(rows).filter { $0 == "City Run" }.count == 2)
}

@Test("a known claim checks exactly one row", arguments: [
    SimulatedLocation.cleared,
    .scenario(name: "City Run"),
    .scenario(name: "Not Listed"),
    .coordinate(latitude: 1, longitude: 2)
])
func knownClaimChecksExactlyOneRow(location: SimulatedLocation) {
    let rows = LocationMenuModel.rows(for: state(location, scenarios: ["City Run", "Apple"]))
    #expect(activeTitles(rows).count == 1)
}

// MARK: - Saved locations

/// File order is menu order, because that file is the user's to
/// arrange. A labeled entry shows its name; an unlabeled one shows its
/// coordinates.
@Test("saved locations appear under Locations in file order")
func savedLocationsAppearInFileOrder() {
    let rows = LocationMenuModel.rows(
        for: state(scenarios: ["City Run"]),
        saved: [
            saved(37.7749, -122.4194, "San Francisco"),
            saved(51.5072, -0.1276, "London"),
            saved(64.1466, -21.9426)
        ]
    )
    #expect(titles(rows) == [
        LocationMenuModel.clearedTitle,
        LocationMenuModel.useMyLocationTitle,
        LocationMenuModel.savedHeader,
        "San Francisco",
        "London",
        "64.1466, -21.9426",
        LocationMenuModel.tripsHeader,
        "City Run",
        LocationMenuModel.customTitle
    ])
}

/// Nothing saved yet is what a fresh install looks like, so the section
/// is omitted rather than shown as an empty header.
@Test("no saved locations means no Locations section")
func emptySavedListOmitsTheSection() {
    let rows = LocationMenuModel.rows(for: state(scenarios: ["City Run"]), saved: [])
    #expect(!titles(rows).contains(LocationMenuModel.savedHeader))
}

@Test("choosing a saved row sends its coordinate")
func savedRowCarriesItsCoordinate() {
    let rows = LocationMenuModel.rows(
        for: state(),
        saved: [saved(37.7749, -122.4194, "San Francisco")]
    )
    let payloads = rows.compactMap { row -> SimulatedLocation? in
        guard case let .location(_, location, _) = row else { return nil }
        return location
    }
    #expect(payloads == [.cleared, .coordinate(latitude: 37.7749, longitude: -122.4194)])
}

/// A claim that matches a saved entry checks *that* row rather than
/// appending a second one below the Trips section.
@Test("an active coordinate checks its saved row")
func activeCoordinateChecksTheSavedRow() {
    let rows = LocationMenuModel.rows(
        for: state(.coordinate(latitude: 37.7749, longitude: -122.4194)),
        saved: [saved(51.5072, -0.1276, "London"), saved(37.7749, -122.4194, "San Francisco")]
    )
    #expect(activeTitles(rows) == ["San Francisco"])
    // No appended duplicate: the saved row absorbed the claim.
    #expect(titles(rows).filter { $0 == "San Francisco" }.count == 1)
}

/// The one-checkmark rule spans sections, not just the list inside one.
@Test("a location saved twice still checks only one row")
func duplicateSavedEntryChecksOneRow() {
    let rows = LocationMenuModel.rows(
        for: state(.coordinate(latitude: 37.7749, longitude: -122.4194)),
        saved: [saved(37.7749, -122.4194, "Home"), saved(37.7749, -122.4194, "Work")]
    )
    #expect(activeTitles(rows) == ["Home"])
}

/// A saved entry whose label is an empty string is treated as
/// unlabeled, so a stray trailing space in the file can't produce a
/// blank menu row.
@Test("an empty label renders as coordinates")
func emptyLabelRendersAsCoordinates() {
    let rows = LocationMenuModel.rows(for: state(), saved: [saved(0, 0, "")])
    #expect(titles(rows).contains("0.0000, 0.0000"))
}

// MARK: - Custom Coordinates

/// Always offered, and always last: the sheet is how the list gets its
/// first entry, so it cannot be gated on there being one.
@Test("Custom Coordinates is always the last row", arguments: [
    PaneLocationStateResult(location: nil, scenarios: []),
    PaneLocationStateResult(location: .cleared, scenarios: ["City Run"]),
    PaneLocationStateResult(location: .scenario(name: "Gone"), scenarios: [])
])
func customRowIsAlwaysLast(state: PaneLocationStateResult) {
    let rows = LocationMenuModel.rows(for: state, saved: [saved(1, 2, "Somewhere")])
    #expect(rows.last == .customCoordinates)
}

/// It opens a sheet rather than applying anything, so it carries no
/// location and can never take the checkmark.
@Test("the Custom row is never checked")
func customRowIsNotSelectable() {
    let rows = LocationMenuModel.rows(
        for: state(.coordinate(latitude: 1, longitude: 2)),
        saved: []
    )
    let customIsALocation = rows.contains { row in
        guard case let .location(title, _, _) = row else { return false }
        return title == LocationMenuModel.customTitle
    }
    #expect(!customIsALocation)
    #expect(activeTitles(rows).count == 1)
}

@Test("coordinates render at four decimal places", arguments: [
    (37.7749, -122.4194, "37.7749, -122.4194"),
    (0.0, 0.0, "0.0000, 0.0000"),
    (-33.8688, 151.2093, "-33.8688, 151.2093")
])
func coordinateFormatting(latitude: Double, longitude: Double, expected: String) {
    #expect(LocationMenuModel.formatCoordinate(latitude: latitude, longitude: longitude) == expected)
}

// MARK: - Use My Location

/// Always offered and always second, directly under `None`. It reads no
/// list, so nothing about the device or the file can gate it, and a row
/// whose position moved with the sections would be hard to hit twice.
@Test("Use My Location is always the second row", arguments: [
    PaneLocationStateResult(location: nil, scenarios: []),
    PaneLocationStateResult(location: .cleared, scenarios: ["City Run"]),
    PaneLocationStateResult(location: .scenario(name: "Gone"), scenarios: [])
])
func useMyLocationIsAlwaysSecond(state: PaneLocationStateResult) {
    let rows = LocationMenuModel.rows(for: state, saved: [saved(1, 2, "Somewhere")])
    #expect(rows.dropFirst().first == .useMyLocation)
}

/// It applies a position that isn't known until it's chosen, so it
/// carries no `SimulatedLocation` and can never take the checkmark. The
/// coordinate it produces gets its own row once the daemon records it.
@Test("the Use My Location row is never checked")
func useMyLocationRowIsNotSelectable() {
    let rows = LocationMenuModel.rows(
        for: state(.coordinate(latitude: 1, longitude: 2)),
        saved: []
    )
    let isALocation = rows.contains { row in
        guard case let .location(title, _, _) = row else { return false }
        return title == LocationMenuModel.useMyLocationTitle
    }
    #expect(!isALocation)
    #expect(activeTitles(rows).count == 1)
}

// MARK: - Routes

/// A route row carries the file path, not a location: the waypoints are
/// in the file, and opening it while a menu is being drawn is exactly
/// what this model exists to avoid.
@Test("a saved route becomes a route row carrying its path")
func savedRouteBecomesARow() {
    let rows = LocationMenuModel.rows(for: state(), saved: [savedRoute("/routes/run.gpx")])
    #expect(rows.contains(.route(title: "run", path: "/routes/run.gpx", isActive: false)))
}

/// The label wins; otherwise the file name without its extension. Not
/// the first waypoint's `<name>`, which would read better and would cost
/// opening every saved `.gpx` on every menu open.
@Test("a route row is titled by its label, else the file name", arguments: [
    (LocationEntry.route(path: "/routes/sunday run.gpx", label: nil), "sunday run"),
    (.route(path: "/routes/run.gpx", label: "Boston Marathon"), "Boston Marathon"),
    (.route(path: "/routes/run.gpx", label: ""), "run")
])
func routeRowTitles(entry: LocationEntry, expected: String) {
    let rows = LocationMenuModel.rows(for: state(), saved: [entry])
    #expect(titles(rows).contains(expected))
}

/// File order is menu order, mixed kinds included: the user arranges the
/// file, so the menu must not group or sort behind their back.
@Test("routes and coordinates interleave in file order")
func mixedEntriesKeepFileOrder() {
    let rows = LocationMenuModel.rows(for: state(), saved: [
        saved(1, 2, "First"),
        savedRoute("/routes/second.gpx"),
        saved(3, 4, "Third")
    ])
    let names = titles(rows)
    let saved = names.drop { $0 != "First" }.prefix(3)
    #expect(Array(saved) == ["First", "second", "Third"])
}

/// The checkmark follows what deviceterm chose, because the claim
/// carries waypoints and the row carries a path.
@Test("the active route path checks its row")
func activeRouteChecksItsRow() {
    let spec = RouteSpec(mode: .interval(seconds: 1), speed: 20, waypoints: [
        RouteWaypoint(latitude: 0, longitude: 0),
        RouteWaypoint(latitude: 1, longitude: 1)
    ])
    let rows = LocationMenuModel.rows(
        for: state(.route(spec: spec)),
        saved: [savedRoute("/routes/run.gpx"), savedRoute("/routes/other.gpx")],
        activeRoutePath: "/routes/run.gpx"
    )
    #expect(activeTitles(rows) == ["run"])
}

/// Without a claim there is nothing to check, whatever the view model
/// last remembered. This is the state a pane reaches after a transfer or
/// a shutdown: the daemon dropped the claim, so no row may assert one.
@Test("a route path with no claim checks nothing")
func activeRouteWithoutAClaimChecksNothing() {
    let rows = LocationMenuModel.rows(
        for: state(),
        saved: [savedRoute("/routes/run.gpx")],
        activeRoutePath: "/routes/run.gpx"
    )
    #expect(activeTitles(rows).isEmpty)
}

/// A one-point `.gpx` applies as a plain coordinate, so without the
/// shared match latch its row and an identically-placed saved point
/// would both check.
@Test("a route and a saved point at the same place check only one row")
func routeAndPointShareOneCheckmark() {
    let rows = LocationMenuModel.rows(
        for: state(.coordinate(latitude: 37.7749, longitude: -122.4194)),
        saved: [savedRoute("/routes/sf.gpx"), saved(37.7749, -122.4194, "SF")],
        activeRoutePath: "/routes/sf.gpx"
    )
    #expect(activeTitles(rows) == ["sf"])
}

/// A claim the menu can't attribute to any row still gets one appended,
/// per the never-lose-the-checkmark rule. It happens for a route started
/// before this GUI came up, or on a pane adopted from another session.
@Test("an unattributable route claim appends a row naming its size")
func unattributableRouteClaimAppendsARow() {
    let spec = RouteSpec(mode: .interval(seconds: 1), speed: 20, waypoints: [
        RouteWaypoint(latitude: 0, longitude: 0),
        RouteWaypoint(latitude: 1, longitude: 1),
        RouteWaypoint(latitude: 2, longitude: 2)
    ])
    let rows = LocationMenuModel.rows(for: state(.route(spec: spec)))
    #expect(activeTitles(rows) == ["Route (3 waypoints)"])
}
