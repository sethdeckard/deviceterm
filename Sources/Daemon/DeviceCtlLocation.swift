// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeviceCtlLocation: `xcrun devicectl device simulate location`, the
// physical-device counterpart to the simulator's `SimLocation` bridge.
//
// Structured like `DeviceCtl`: a pure `arguments(for:)` builds the argv
// and a pure `parseScenarios` decodes the payload, so both are
// fixture-tested without spawning anything. `--json-output` is the only
// interface devicectl documents as supported for programmatic consumers,
// so results are read from a temp file rather than stdout.
//
// Unlike `DeviceCtl.listPhysicalDevices`, a non-zero exit **throws**
// instead of degrading to an empty result. An enumeration that comes
// back empty is a usable answer; a location set that silently did
// nothing is not. Unknown scenario names exit non-zero with the reason
// on stderr, so the tool reports its own rejection and this type needs
// no name pre-validation of its own.
//
// Each invocation waits for `devicectl` to exit, then retains no
// keepalive process: an accepted simulation continues on the device
// afterwards, including a multi-minute scenario, and a later `clear`
// still finds it active. The device runs the route; the Mac starts it.

import DaemonProtocol
import Foundation

/// One `devicectl device simulate location` invocation.
enum DeviceCtlLocationCommand: Equatable, Sendable {
    case coordinate(latitude: Double, longitude: Double)
    case scenario(name: String)
    /// `routePath` is a file this type wrote, holding the JSON
    /// `--route-file` expects.
    case route(routePath: String)
    case list
    case clear
}

enum DeviceCtlLocationError: Error, Equatable {
    /// A non-zero exit not classified as `unknownScenario`. Carries
    /// devicectl's own stderr when it wrote any. A spawn failure arrives
    /// here too, as status `-1` with the launch error as the message, so
    /// there is no separate launch case.
    case commandFailed(status: Int32, message: String)
    /// devicectl rejected the scenario name. Split out from
    /// `commandFailed` because it is the one location failure the *caller*
    /// can fix, so it reaches the wire as `invalidParams` rather than a
    /// generic server error, matching how the simulator backend answers
    /// the same mistake.
    case unknownScenario(name: String)
    /// Exit 0 but no readable `--json-output` payload.
    case missingOutput
    /// Exit 0 with a payload that isn't the expected shape.
    case malformedOutput
    /// The route file couldn't be written, so `devicectl` was never run.
    /// A full or unwritable temp directory is the realistic cause.
    case routeFileUnwritable(message: String)
}

/// The `--route-file` document, in devicectl's own documented schema
/// rather than deviceterm's wire shape.
///
/// Kept as an explicit `Encodable` rather than re-encoding `RouteSpec`,
/// because the two disagree deliberately: devicectl flattens the mode
/// into a `"mode"` string plus a sibling field, while the wire type
/// makes the pairing unrepresentable. Writing the translation out is
/// what lets a test pin the tool's format.
struct DeviceCtlRouteFile: Encodable, Equatable {
    struct Waypoint: Encodable, Equatable {
        let latitude: Double
        let longitude: Double
    }

    let mode: String
    /// Present only in distance mode; devicectl requires the field that
    /// matches `mode` and ignores the other.
    let distance: Double?
    /// Present only in interval mode.
    let interval: Double?
    let speed: Double
    let waypoints: [Waypoint]

    init(_ spec: RouteSpec) {
        switch spec.mode {
        case let .distance(meters):
            mode = "distance"
            distance = meters
            interval = nil

        case let .interval(seconds):
            mode = "interval"
            distance = nil
            interval = seconds
        }
        speed = spec.speed
        waypoints = spec.waypoints.map {
            Waypoint(latitude: $0.latitude, longitude: $0.longitude)
        }
    }
}

// The failure half of a devicectl `--json-output` payload. Only the
// fields needed to classify the failure; devicectl writes many more.
private struct DeviceCtlErrorOutput: Decodable {
    let error: DeviceCtlErrorBody
}

private struct DeviceCtlErrorBody: Decodable {
    let code: Int
    let domain: String
}

// Decoded `devicectl device simulate location list --json-output`
// payload. File-scope to stay inside the 2-level type-nesting limit.
private struct DeviceCtlLocationOutput: Decodable {
    let result: DeviceCtlLocationResult
}

private struct DeviceCtlLocationResult: Decodable {
    /// The key is `availableScenarios`, not `scenarios` (devicectl
    /// 629.3, `jsonVersion` 4). The test fixture is a sanitized capture
    /// of that output.
    ///
    /// **Deliberately non-optional.** An optional here would turn a
    /// missing or renamed key into an empty list, reporting every device
    /// as having no trips without erroring anywhere. Requiring the key
    /// means a shape change fails the decode and surfaces as
    /// `malformedOutput`, while a device that genuinely has no scenarios
    /// says so with `"availableScenarios": []`.
    let availableScenarios: [DeviceCtlLocationScenario]
}

private struct DeviceCtlLocationScenario: Decodable {
    let name: String?
    let localizedName: String?
}

/// What one `devicectl` invocation produced: its exit status, the
/// contents of the `--json-output` file (nil when it wrote none), and
/// whatever it put on stderr.
struct DeviceCtlRun: Sendable {
    let status: Int32
    let json: Data?
    let stderr: String
}

struct DeviceCtlLocation: DeviceLocationSimulating {
    /// Spawn seam so tests can drive the pure argv/parse halves without
    /// running the real tool. Returns the process exit status, the
    /// contents of the `--json-output` file, and stderr.
    typealias Runner = @Sendable (
        _ arguments: [String],
        _ jsonPath: String
    ) async -> DeviceCtlRun

    /// CoreDevice reports an unknown scenario with domain
    /// `com.apple.dt.CoreDeviceError`, code 20001, written to the
    /// `--json-output` error payload alongside a non-zero exit.
    ///
    /// Classifying on the structured code rather than stderr's English
    /// sentence keeps this from breaking on a reworded or localized
    /// message, and `--json-output` is the interface devicectl documents
    /// for programmatic consumers.
    static let scenarioNotFoundCode = 20_001
    static let coreDeviceErrorDomain = "com.apple.dt.CoreDeviceError"

    private let run: Runner

    init(run: Runner? = nil) {
        if let run {
            self.run = run
        } else {
            // `RealDeviceBackend` owns one DeviceCtlLocation per device. Its
            // own location pump orders mutations for that device; this queue
            // moves the synchronous process wait off Swift's cooperative pool
            // without blocking another device's runner.
            let processQueue = BlockingWorkQueue(
                label: "com.deviceterm.daemon.devicectl-location.\(UUID().uuidString)"
            )
            self.run = Self.productionRunner(on: processQueue)
        }
    }

    /// Production runner. Reads the `--json-output` file and removes it before
    /// returning, so nothing accumulates in the temp dir.
    private static func productionRunner(on processQueue: BlockingWorkQueue) -> Runner {
        { arguments, jsonPath in
            await processQueue.run {
                defer { try? FileManager.default.removeItem(atPath: jsonPath) }
                let process = Process()
                process.launchPath = "/usr/bin/xcrun"
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                let errPipe = Pipe()
                process.standardError = errPipe
                do {
                    try process.run()
                } catch {
                    return DeviceCtlRun(status: -1, json: nil, stderr: "\(error)")
                }
                // Drain stderr before waiting: devicectl's diagnostics are
                // small, but a full pipe buffer would deadlock the wait.
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return DeviceCtlRun(
                    status: process.terminationStatus,
                    json: FileManager.default.contents(atPath: jsonPath),
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                )
            }
        }
    }

    // MARK: Pure

    /// The argv after `xcrun`. Flag names are the contract with the
    /// tool, so they are pinned by tests rather than assembled ad hoc at
    /// each call site.
    static func arguments(
        for command: DeviceCtlLocationCommand,
        deviceId: String,
        jsonPath: String
    ) -> [String] {
        var argv = ["devicectl", "device", "simulate", "location"]
        switch command {
        case let .coordinate(latitude, longitude):
            argv += [
                "coordinate",
                "--device", deviceId,
                "--latitude", String(latitude),
                "--longitude", String(longitude)
            ]

        case let .scenario(name):
            argv += ["scenario", "--device", deviceId, name]

        case let .route(routePath):
            // `--route-file` rather than the `--waypoints` flag: the
            // file form is the one devicectl documents a schema for, and
            // it keeps a route's size independent of the process
            // argument limit however long the route gets.
            argv += ["route", "--device", deviceId, "--route-file", routePath]

        case .list:
            argv += ["list", "--device", deviceId]

        case .clear:
            argv += ["clear", "--device", deviceId]
        }
        return argv + ["--json-output", jsonPath]
    }

    /// Decode a `list` payload into scenario names. Prefers `name` (what
    /// `scenario` consumes) and falls back to `localizedName`.
    ///
    /// **Every entry must yield a usable name.** A `compactMap` here
    /// would drop unreadable entries and hand back a shorter (possibly
    /// empty) list, so renaming the per-entry fields would turn a
    /// populated payload into `[]` without an error, the same silence the
    /// required `availableScenarios` key prevents one level up. Dropping
    /// even one entry would also offer a trip list the device did not
    /// report. The `localizedName` fallback is kept, so a payload
    /// carrying only that still decodes.
    static func parseScenarios(_ data: Data) throws -> [String] {
        guard let output = try? JSONDecoder().decode(DeviceCtlLocationOutput.self, from: data) else {
            throw DeviceCtlLocationError.malformedOutput
        }
        return try output.result.availableScenarios.map { entry in
            guard let name = entry.name ?? entry.localizedName, !name.isEmpty else {
                throw DeviceCtlLocationError.malformedOutput
            }
            return name
        }
    }

    /// The bytes of the `--route-file` document for `spec`.
    ///
    /// Keys are sorted so the file is stable across runs, which makes it
    /// diffable when a route misbehaves and makes the test's expectation
    /// a literal rather than a parse.
    static func routeFileJSON(for spec: RouteSpec) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(DeviceCtlRouteFile(spec))
    }

    /// A private temp path, tagged with the kind of file it holds so a
    /// leftover after a crash says what it was.
    static func temporaryPath(suffix: String) -> String {
        NSTemporaryDirectory()
            + "deviceterm-devicectl-loc-\(ProcessInfo.processInfo.processIdentifier)-"
            + UUID().uuidString + "-" + suffix + ".json"
    }

    /// Whether a failure payload says the scenario name was rejected.
    static func isUnknownScenarioFailure(_ data: Data?) -> Bool {
        guard let data,
            let output = try? JSONDecoder().decode(DeviceCtlErrorOutput.self, from: data) else {
            return false
        }
        return output.error.code == scenarioNotFoundCode
            && output.error.domain == coreDeviceErrorDomain
    }

    // MARK: DeviceLocationSimulating

    func setCoordinate(deviceId: String, latitude: Double, longitude: Double) async throws {
        _ = try await invoke(.coordinate(latitude: latitude, longitude: longitude), deviceId: deviceId)
    }

    func setScenario(deviceId: String, name: String) async throws {
        _ = try await invoke(.scenario(name: name), deviceId: deviceId)
    }

    /// Write the route document, run `devicectl`, then remove the file.
    ///
    /// The file only has to outlive the subprocess, and `invoke` doesn't
    /// return until `devicectl` has exited, so the `defer` can't pull it
    /// out from under a still-running tool. The route itself keeps
    /// playing on the device afterwards: nothing device-side refers back
    /// to this path.
    func startRoute(deviceId: String, spec: RouteSpec) async throws {
        let path = Self.temporaryPath(suffix: "route")
        do {
            try Self.routeFileJSON(for: spec).write(to: URL(fileURLWithPath: path))
        } catch {
            throw DeviceCtlLocationError.routeFileUnwritable(message: "\(error)")
        }
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try await invoke(.route(routePath: path), deviceId: deviceId)
    }

    func clear(deviceId: String) async throws {
        _ = try await invoke(.clear, deviceId: deviceId)
    }

    func availableScenarios(deviceId: String) async throws -> [String] {
        guard let json = try await invoke(.list, deviceId: deviceId) else {
            throw DeviceCtlLocationError.missingOutput
        }
        return try Self.parseScenarios(json)
    }

    // MARK: Spawn

    @discardableResult
    private func invoke(
        _ command: DeviceCtlLocationCommand,
        deviceId: String
    ) async throws -> Data? {
        let jsonPath = Self.temporaryPath(suffix: "out")
        let argv = Self.arguments(for: command, deviceId: deviceId, jsonPath: jsonPath)
        let result = await run(argv, jsonPath)
        guard result.status == 0 else {
            // A rejected scenario name is the caller's mistake, so it
            // gets its own case and reaches the wire as `invalidParams`;
            // everything else is an operational failure. Only a scenario
            // set can produce it, so the classification is scoped to that
            // command rather than trusting the code in isolation.
            if case let .scenario(name) = command,
                Self.isUnknownScenarioFailure(result.json) {
                throw DeviceCtlLocationError.unknownScenario(name: name)
            }
            throw DeviceCtlLocationError.commandFailed(
                status: result.status,
                message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result.json
    }
}
