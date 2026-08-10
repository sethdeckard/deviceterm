// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// DeviceCtlLocationTests: the pure argument builder and scenario parser.
// `arguments(for:)` is the contract with devicectl's CLI, so every flag
// name is pinned here. The fixture pins the output shape, and the fake
// runner avoids subprocesses.

private func loadFixture() throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: "devicectl-location-list", withExtension: "json")
    )
    return try Data(contentsOf: url)
}

// MARK: - argv

@Test("coordinate passes latitude and longitude as separate flags")
func coordinateArguments() {
    let argv = DeviceCtlLocation.arguments(
        for: .coordinate(latitude: 37.3349, longitude: -122.009),
        deviceId: "DEV-1",
        jsonPath: "/tmp/out.json"
    )
    #expect(argv == [
        "devicectl", "device", "simulate", "location", "coordinate",
        "--device", "DEV-1",
        "--latitude", "37.3349",
        "--longitude", "-122.009",
        "--json-output", "/tmp/out.json"
    ])
}

/// The scenario name is a bare positional, not a flagged value. Getting
/// this wrong makes devicectl read it as a subcommand.
@Test("scenario passes the name positionally")
func scenarioArguments() {
    let argv = DeviceCtlLocation.arguments(
        for: .scenario(name: "City Run"),
        deviceId: "DEV-1",
        jsonPath: "/tmp/out.json"
    )
    #expect(argv == [
        "devicectl", "device", "simulate", "location", "scenario",
        "--device", "DEV-1",
        "City Run",
        "--json-output", "/tmp/out.json"
    ])
}

@Test("list and clear take only the device", arguments: [
    (DeviceCtlLocationCommand.list, "list"),
    (DeviceCtlLocationCommand.clear, "clear")
])
func simpleArguments(command: DeviceCtlLocationCommand, verb: String) {
    let argv = DeviceCtlLocation.arguments(
        for: command,
        deviceId: "DEV-1",
        jsonPath: "/tmp/out.json"
    )
    #expect(argv == [
        "devicectl", "device", "simulate", "location", verb,
        "--device", "DEV-1",
        "--json-output", "/tmp/out.json"
    ])
}

/// `--json-output` is the only interface devicectl documents as
/// supported for programmatic consumers, so every command must carry it.
@Test("every command requests JSON output")
func everyCommandRequestsJSON() {
    let commands: [DeviceCtlLocationCommand] = [
        .coordinate(latitude: 0, longitude: 0),
        .scenario(name: "x"),
        .list,
        .clear
    ]
    for command in commands {
        let argv = DeviceCtlLocation.arguments(
            for: command,
            deviceId: "D",
            jsonPath: "/tmp/p.json"
        )
        #expect(argv.suffix(2) == ["--json-output", "/tmp/p.json"])
    }
}

// MARK: - Parsing

@Test("parseScenarios reads the built-in trips in order")
func parseScenariosReadsNames() throws {
    let names = try DeviceCtlLocation.parseScenarios(loadFixture())
    #expect(names == ["City Run", "City Bicycle Ride", "Apple", "Freeway Drive"])
}

/// The payload key is `availableScenarios`. A wrong or missing key must
/// fail rather than look like an empty scenario list, which would report
/// every device as having no trips while erroring nowhere.
@Test("parseScenarios rejects a payload keyed the wrong way")
func parseScenariosRequiresTheDocumentedKey() {
    let data = Data(#"{"result":{"scenarios":[{"name":"City Run"}]}}"#.utf8)
    #expect(throws: DeviceCtlLocationError.malformedOutput) {
        try DeviceCtlLocation.parseScenarios(data)
    }
}

@Test("parseScenarios rejects a payload missing the key entirely")
func parseScenariosRejectsMissingKey() {
    #expect(throws: DeviceCtlLocationError.malformedOutput) {
        try DeviceCtlLocation.parseScenarios(Data(#"{"result":{}}"#.utf8))
    }
}

/// A device with no scenarios says so explicitly, and that is the only
/// thing that reads as empty.
@Test("parseScenarios accepts an explicitly empty list")
func parseScenariosAcceptsExplicitEmpty() throws {
    let data = Data(#"{"result":{"availableScenarios":[]}}"#.utf8)
    #expect(try DeviceCtlLocation.parseScenarios(data).isEmpty)
}

/// Entry-level drift is the same silence one level down: with a
/// `compactMap`, renaming the per-entry fields turns a populated list
/// into an empty one with no error. Every entry must yield a usable
/// name or the whole payload is malformed.
@Test("parseScenarios rejects entries it can't name", arguments: [
    // Entries present, but none carries a recognized name field.
    #"{"result":{"availableScenarios":[{},{}]}}"#,
    // Per-entry key renamed, the drift this guards against.
    #"{"result":{"availableScenarios":[{"title":"City Run"}]}}"#,
    // One good entry, one unreadable: dropping the bad one would offer
    // a trip list the device never reported.
    #"{"result":{"availableScenarios":[{"name":"City Run"},{}]}}"#,
    // Present but empty, so not a name `scenario` could consume.
    #"{"result":{"availableScenarios":[{"name":""}]}}"#
])
func parseScenariosRejectsUnnamedEntries(payload: String) {
    #expect(throws: DeviceCtlLocationError.malformedOutput) {
        try DeviceCtlLocation.parseScenarios(Data(payload.utf8))
    }
}

/// The `localizedName` fallback survives that tightening: a payload
/// carrying only it still decodes.
@Test("parseScenarios falls back to localizedName")
func parseScenariosFallsBackToLocalizedName() throws {
    let data = Data(#"{"result":{"availableScenarios":[{"localizedName":"City Run"}]}}"#.utf8)
    #expect(try DeviceCtlLocation.parseScenarios(data) == ["City Run"])
}

@Test("parseScenarios rejects a payload that isn't devicectl JSON")
func parseScenariosRejectsGarbage() {
    #expect(throws: DeviceCtlLocationError.malformedOutput) {
        try DeviceCtlLocation.parseScenarios(Data("not json".utf8))
    }
}

// MARK: - Failure classification

/// CoreDevice reports an unknown scenario with domain
/// `com.apple.dt.CoreDeviceError`, code 20001 (devicectl 629.3).
/// Classifying on the structured code rather than stderr's English
/// sentence keeps this from breaking on a reworded or localized
/// message.
private let unknownScenarioPayload = Data(#"""
{"error":{"code":20001,"domain":"com.apple.dt.CoreDeviceError",
"userInfo":{"NSLocalizedDescription":{"string":"Scenario 'Nope' not found."}}}}
"""#.utf8)

@Test("the scenario-not-found payload is recognized")
func recognizesUnknownScenarioPayload() {
    #expect(DeviceCtlLocation.isUnknownScenarioFailure(unknownScenarioPayload))
}

@Test("other failures are not misread as a bad scenario name", arguments: [
    Data(#"{"error":{"code":20001,"domain":"com.apple.SomethingElse"}}"#.utf8),
    Data(#"{"error":{"code":9999,"domain":"com.apple.dt.CoreDeviceError"}}"#.utf8),
    Data(#"{"info":{"outcome":"failed"}}"#.utf8),
    Data("not json".utf8)
])
func rejectsUnrelatedFailurePayloads(payload: Data) {
    #expect(!DeviceCtlLocation.isUnknownScenarioFailure(payload))
}

@Test("a missing payload is not a bad scenario name")
func missingPayloadIsNotUnknownScenario() {
    #expect(!DeviceCtlLocation.isUnknownScenarioFailure(nil))
}

/// A bad name gets its own error so it can reach the wire as
/// `invalidParams`, matching how the simulator backend answers the same
/// mistake. Without the split it would be an opaque `commandFailed`.
@Test("a rejected scenario name throws unknownScenario")
func rejectedScenarioThrowsItsOwnError() async {
    let subject = DeviceCtlLocation { _, _ in
        DeviceCtlRun(status: 1, json: unknownScenarioPayload, stderr: "ERROR: Scenario 'Nope' not found.")
    }
    await #expect(throws: DeviceCtlLocationError.unknownScenario(name: "Nope")) {
        try await subject.setScenario(deviceId: "DEV-1", name: "Nope")
    }
}

/// The classification is scoped to the scenario command, so an unrelated
/// verb that happens to report the same code stays a plain failure.
@Test("a non-scenario command never reports unknownScenario")
func nonScenarioCommandStaysCommandFailed() async {
    let subject = DeviceCtlLocation { _, _ in
        DeviceCtlRun(status: 1, json: unknownScenarioPayload, stderr: "boom")
    }
    await #expect(throws: DeviceCtlLocationError.commandFailed(status: 1, message: "boom")) {
        try await subject.clear(deviceId: "DEV-1")
    }
}

// MARK: - Dispatch

/// A non-zero exit must throw rather than degrade. Unlike the roster
/// enumeration, where an empty result is a usable answer, a location set
/// that silently did nothing is not.
@Test("a non-zero exit throws and carries devicectl's message")
func nonZeroExitThrows() async {
    let subject = DeviceCtlLocation { _, _ in
        DeviceCtlRun(status: 1, json: nil, stderr: "  device not found\n")
    }
    await #expect(throws: DeviceCtlLocationError.commandFailed(
        status: 1,
        message: "device not found"
    )) {
        try await subject.clear(deviceId: "DEV-1")
    }
}

@Test("a launch failure surfaces as a failed command")
func launchFailureThrows() async {
    let subject = DeviceCtlLocation { _, _ in
        DeviceCtlRun(status: -1, json: nil, stderr: "no such tool")
    }
    await #expect(throws: (any Error).self) {
        try await subject.setCoordinate(deviceId: "DEV-1", latitude: 1, longitude: 2)
    }
}

/// Exit 0 with no readable payload is distinct from a command failure:
/// the tool ran, but there is nothing to decode.
@Test("list with no payload throws missingOutput")
func listWithoutPayloadThrows() async {
    let subject = DeviceCtlLocation { _, _ in
        DeviceCtlRun(status: 0, json: nil, stderr: "")
    }
    await #expect(throws: DeviceCtlLocationError.missingOutput) {
        _ = try await subject.availableScenarios(deviceId: "DEV-1")
    }
}

@Test("availableScenarios decodes the runner's payload")
func availableScenariosDecodes() async throws {
    let fixture = try loadFixture()
    let subject = DeviceCtlLocation { _, _ in
        DeviceCtlRun(status: 0, json: fixture, stderr: "")
    }
    let names = try await subject.availableScenarios(deviceId: "DEV-1")
    #expect(names.contains("Freeway Drive"))
}

/// The deviceId reaches the argv rather than being dropped somewhere in
/// the dispatch chain.
@Test("the deviceId threads through to the invocation")
func deviceIdReachesArgv() async throws {
    let captured = CapturedArgv()
    let subject = DeviceCtlLocation { argv, _ in
        await captured.record(argv)
        return DeviceCtlRun(status: 0, json: nil, stderr: "")
    }
    try await subject.setScenario(deviceId: "ABC-123", name: "City Run")
    let argv = await captured.value
    #expect(argv.contains("ABC-123"))
    #expect(argv.contains("City Run"))
}

private actor CapturedArgv {
    private(set) var value: [String] = []
    func record(_ argv: [String]) { value = argv }
}

// MARK: - Routes

private let routeSpec = RouteSpec(
    mode: .interval(seconds: 2),
    speed: 5,
    waypoints: [
        RouteWaypoint(latitude: 37.7749, longitude: -122.4194),
        RouteWaypoint(latitude: 40.7128, longitude: -74.006)
    ]
)

/// `--route-file` rather than `--waypoints`: the file form is the one
/// devicectl documents a schema for, and it keeps the request from
/// scaling argv with the waypoint count.
@Test("route passes a file path, not inline waypoints")
func routeArguments() {
    let argv = DeviceCtlLocation.arguments(
        for: .route(routePath: "/tmp/route.json"),
        deviceId: "DEV-1",
        jsonPath: "/tmp/out.json"
    )
    #expect(argv == [
        "devicectl", "device", "simulate", "location", "route",
        "--device", "DEV-1",
        "--route-file", "/tmp/route.json",
        "--json-output", "/tmp/out.json"
    ])
}

/// devicectl's own documented schema, which deliberately differs from
/// the wire type: it flattens the mode into a string plus a sibling
/// field, where `RouteSpec.Mode` makes the pairing unrepresentable. This
/// is the translation, so it is pinned as literal bytes.
@Test("the route file matches devicectl's documented schema")
func routeFileSchema() throws {
    let json = try #require(String(bytes: DeviceCtlLocation.routeFileJSON(for: routeSpec), encoding: .utf8))
    #expect(json == #"{"interval":2,"mode":"interval","speed":5,"#
        + #""waypoints":[{"latitude":37.7749,"longitude":-122.4194},"#
        + #"{"latitude":40.7128,"longitude":-74.006}]}"#)
}

/// Only the field matching `mode` is written. Emitting both would leave
/// devicectl to pick, which its help says it does not promise to do the
/// way we intend.
@Test("distance mode writes distance and omits interval")
func routeFileDistanceMode() throws {
    var spec = routeSpec
    spec.mode = .distance(meters: 100)
    let json = try #require(String(bytes: DeviceCtlLocation.routeFileJSON(for: spec), encoding: .utf8))
    #expect(json.contains(#""mode":"distance""#))
    #expect(json.contains(#""distance":100"#))
    #expect(!json.contains("interval"))
}

/// The file has to exist while devicectl runs and not afterwards. Both
/// halves are asserted from the runner, which is the only moment the
/// subprocess would be looking at it.
@Test("the route file exists during the run and is removed after")
func routeFileLifecycle() async throws {
    let observed = ObservedRouteFile()
    let subject = DeviceCtlLocation { argv, _ in
        // The path devicectl was handed, read back from the argv it
        // would actually have received.
        guard let index = argv.firstIndex(of: "--route-file"),
            argv.indices.contains(index + 1) else {
            return DeviceCtlRun(status: 1, json: nil, stderr: "no --route-file")
        }
        let path = argv[index + 1]
        let contents = FileManager.default.contents(atPath: path)
        await observed.record(path: path, contents: contents)
        return DeviceCtlRun(status: 0, json: nil, stderr: "")
    }
    try await subject.startRoute(deviceId: "DEV-1", spec: routeSpec)

    let path = await observed.path
    let contents = try #require(await observed.contents, "the file was absent while devicectl ran")
    #expect(contents == (try DeviceCtlLocation.routeFileJSON(for: routeSpec)))
    #expect(!FileManager.default.fileExists(atPath: path), "the route file was left behind")
}

/// A non-zero exit throws for a route exactly as it does for the other
/// verbs: a route that silently did not start is worse than an error.
@Test("a failing route run throws")
func failingRouteThrows() async {
    let subject = DeviceCtlLocation { _, _ in
        DeviceCtlRun(status: 1, json: nil, stderr: "device is locked")
    }
    await #expect(
        throws: DeviceCtlLocationError.commandFailed(status: 1, message: "device is locked")
    ) {
        try await subject.startRoute(deviceId: "DEV-1", spec: routeSpec)
    }
}

/// The route file is written before devicectl is spawned, so an
/// unwritable path fails without running anything at all.
@Test("an unwritable route file fails before devicectl runs")
func unwritableRouteFileFailsEarly() async throws {
    let ran = SpawnFlag()
    let subject = DeviceCtlLocation { _, _ in
        await ran.set()
        return DeviceCtlRun(status: 0, json: nil, stderr: "")
    }
    // A waypoint that can't be encoded: `Double.nan` has no JSON
    // spelling, so `routeFileJSON` throws before anything is written.
    var spec = routeSpec
    spec.waypoints[0] = RouteWaypoint(latitude: .nan, longitude: 0)
    do {
        try await subject.startRoute(deviceId: "DEV-1", spec: spec)
        Issue.record("expected a failure")
    } catch let error as DeviceCtlLocationError {
        guard case .routeFileUnwritable = error else {
            Issue.record("expected routeFileUnwritable, got \(error)")
            return
        }
    }
    #expect(await ran.value == false, "devicectl ran despite an unwritable route file")
}

private actor ObservedRouteFile {
    private(set) var path = ""
    private(set) var contents: Data?
    func record(path: String, contents: Data?) {
        self.path = path
        self.contents = contents
    }
}

private actor SpawnFlag {
    private(set) var value = false
    func set() { value = true }
}
