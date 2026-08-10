// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import Foundation
import Testing

// Live location simulation against a booted sim. Deliberate
// `make test-live` track; the hermetic construction/error-path checks
// stay in CoreSimulatorBridgeTests.
private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

/// The scenario names Apple ships. Asserted as a *subset* so additional
/// scenarios are accepted, while a missing known entry exposes decoding
/// or compatibility drift.
private let expectedScenarios = [
    "City Run",
    "City Bicycle Ride",
    "Freeway Drive",
    "Apple"
]

@Test
func availableScenariosListsTheBuiltInTrips() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let client = try SimLocation.client(forUDID: booted.udid)
    let scenarios = try client.availableScenarios()

    #expect(!scenarios.isEmpty, "runtime reported no location scenarios at all")
    for expected in expectedScenarios {
        #expect(
            scenarios.contains(expected),
            "built-in scenario '\(expected)' missing; runtime now offers \(scenarios)"
        )
    }
}

/// Scenario enumeration **requires a booted device**: a shut-down one
/// returns an empty list rather than the four built-ins.
///
/// Live-verified, and it matches `simctl`: `xcrun simctl location
/// <shutdown-udid> list` prints only the table header. An empty list is
/// a normal cold-device state, not an error condition, so a caller
/// showing these must repopulate once the device boots.
///
@Test
func availableScenariosOnShutDownDeviceIsEmpty() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try? SimDeviceHandle.singleBootedDevice()
    let devices = try SimDeviceHandle.allDevices()
    let shutDown = try #require(
        devices.first { $0.udid != booted?.udid },
        "need at least one non-booted device in the set"
    )
    let client = try SimLocation.client(forUDID: shutDown.udid)

    // Deliberately unguarded: a throw is a regression from the verified
    // "returns an empty array" behavior, so it must fail the test rather
    // than be absorbed as an acceptable alternative outcome.
    let scenarios = try client.availableScenarios()
    #expect(
        scenarios.isEmpty,
        "a shut-down device is expected to vend no scenarios; got \(scenarios)"
    )
}

@Test
func setCoordinateThenScenarioThenClearRoundTrips() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let client = try SimLocation.client(forUDID: booted.udid)
    // Best-effort net for the *throwing* paths only: an error from the
    // scenario lookup or activation below would otherwise leave this
    // host's sim carrying a location override into every later test.
    // The success path clears explicitly instead, so a broken `clear`
    // fails the test rather than being swallowed by `try?`.
    var cleared = false
    defer { if !cleared { try? client.clear() } }

    // Apple Park.
    try client.setCoordinate(latitude: 37.3349, longitude: -122.0090)

    let scenarios = try client.availableScenarios()
    if let trip = scenarios.first {
        try client.setScenario(trip)
    }

    // The assertion the deferred cleanup can't make:
    // `clearSimulatedLocationWithError:` must actually succeed.
    try client.clear()
    cleared = true
}

/// `setLocationScenario:error:` does **not** validate the name. An
/// unknown scenario is accepted silently, with no error and no effect.
///
/// Live-verified, and it contradicts what `simctl` appears to do:
/// `xcrun simctl location <udid> run "Bogus"` prints
/// "Could not find scenario 'Bogus'", but that check is simctl's own,
/// performed client-side against the scenario list before it ever calls
/// this selector.
///
/// The consequence is a caller obligation, which is why this is pinned:
/// anything driving `setScenario(_:)` must validate the name against
/// `availableScenarios()` first, or a typo silently no-ops.
@Test
func setScenarioWithUnknownNameIsSilentlyAccepted() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let client = try SimLocation.client(forUDID: booted.udid)
    defer { try? client.clear() }

    // This must not throw; that is the behavior under test.
    try client.setScenario("Definitely Not A Real Scenario")
}

// MARK: - Routes

/// The waypoint shape, against a real runtime.
///
/// It was recovered statically first, from `simctl`'s own machine code:
/// its parser splits each `lat,lon` argument, calls
/// `+[NSNumber numberWithDouble:]` on both halves, and appends each into
/// one flat array, then reports `count / 2` as the waypoint total.
///
/// This confirms a live runtime **accepts** that shape on both
/// selectors, which is the most an automated check can establish here:
/// the selectors return a plain `BOOL` and there is no getter, so
/// nothing in-process can observe the device actually moving. Confirming
/// the route plays is a manual step (`Tests/Manual/location.md`). Both cadences are
/// exercised because they are separate selectors and a runtime could
/// drop one without the other.
@Test
func startRouteAcceptsAFlatWaypointArray() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let client = try SimLocation.client(forUDID: booted.udid)
    var cleared = false
    defer { if !cleared { try? client.clear() } }

    // Two waypoints: Apple Park to Shoreline, as four alternating
    // latitude/longitude values in one array.
    let waypoints = [37.3349, -122.0090, 37.4220, -122.0841].map { NSNumber(value: $0) }
    try client.startRoute(interval: 1, speed: 20, waypoints: waypoints)
    try client.startRoute(distance: 50, speed: 20, waypoints: waypoints)

    try client.clear()
    cleared = true
}

/// simctl rejects fewer than two waypoints client-side ("Must specify at
/// least two waypoints"), which says the selector behind it does not.
/// The wrapper checks arity itself rather than handing a short array to
/// a private selector that will archive and ship it regardless.
///
/// Asserted on the wrapper's own wording, not merely on "it threw". A
/// *booted* device may well reject a one-waypoint route on its own, and
/// then the guard could be deleted with this test still green.
@Test
func startRouteRejectsTooFewWaypointsAgainstARealDevice() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let client = try SimLocation.client(forUDID: booted.udid)
    defer { try? client.clear() }

    do {
        try client.startRoute(
            interval: 1,
            speed: 20,
            waypoints: [NSNumber(value: 37.3349), NSNumber(value: -122.009)]
        )
        Issue.record("a one-waypoint route was accepted")
    } catch {
        #expect(
            (error as NSError).localizedDescription.contains("at least two waypoints"),
            "rejected, but not by the wrapper's arity check: \(error)"
        )
    }
}
