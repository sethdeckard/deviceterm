// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// `xcrun devicectl device orientation`, which lays a Simulator face up or
/// face down.
///
/// The PurpleHID orientation event takes only the four display orientations,
/// and the vendor HID payload a foldable rotates with is ignored by every
/// other Simulator, so this is the path for a flat orientation on an ordinary
/// Simulator. `get` reports the device orientation as soon as `set` returns,
/// which is what lets the result be confirmed rather than assumed.
///
/// Structured like `DeviceCtlLocation`: pure argv and parse halves, tested
/// without spawning, behind an injectable runner. The runner is synchronous
/// because the caller already runs it on the backend's blocking input queue.
struct DeviceCtlOrientation: Sendable {
    /// Runs `xcrun` with the arguments and returns what `devicectl`
    /// produced, including the `--json-output` file at the path given.
    typealias Runner = @Sendable (_ arguments: [String], _ jsonPath: String) -> DeviceCtlRun

    // The `get` and `set` payloads share this shape. Only the field read.
    private struct Output: Decodable {
        let result: Reading
    }

    private struct Reading: Decodable {
        let deviceOrientation: String
    }

    private static let productionRunner: Runner = { arguments, jsonPath in
        defer { try? FileManager.default.removeItem(atPath: jsonPath) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return DeviceCtlRun(status: -1, json: nil, stderr: "\(error)")
        }
        // Drain stderr before waiting, so a full pipe cannot deadlock it.
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return DeviceCtlRun(
            status: process.terminationStatus,
            json: FileManager.default.contents(atPath: jsonPath),
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    private let run: Runner

    init(run: Runner? = nil) {
        self.run = run ?? Self.productionRunner
    }

    // MARK: Pure

    /// The argv after `xcrun` for `set`. The value is the wire name, which
    /// `devicectl` accepts as it is.
    static func setArguments(_ flat: FlatOrientation, deviceId: String, jsonPath: String) -> [String] {
        [
            "devicectl", "device", "orientation", "set", "--device", deviceId, flat.rawValue,
            "--json-output", jsonPath, "--quiet"
        ]
    }

    /// The argv after `xcrun` for `get`.
    static func getArguments(deviceId: String, jsonPath: String) -> [String] {
        [
            "devicectl", "device", "orientation", "get", "--device", deviceId,
            "--json-output", jsonPath, "--quiet"
        ]
    }

    /// The device orientation a `get` payload reports, as `devicectl` names
    /// it: one of the six orientations, or `unknown`.
    static func deviceOrientation(fromJSON data: Data) -> String? {
        try? JSONDecoder().decode(Output.self, from: data).result.deviceOrientation
    }

    private static func temporaryPath() -> String {
        NSTemporaryDirectory()
            + "deviceterm-devicectl-orientation-\(ProcessInfo.processInfo.processIdentifier)-"
            + UUID().uuidString + ".json"
    }

    // MARK: Commands

    /// Lay the device `flat`, then read back what it reports.
    ///
    /// Returns `devicectl`'s name for the orientation it read, which equals
    /// `flat.rawValue` when the request took. Throws
    /// `DeviceBackendError.orientationCommandFailed` if either command fails
    /// or `get` returns no readable orientation.
    func set(_ flat: FlatOrientation, deviceId: String) throws -> String {
        let setPath = Self.temporaryPath()
        try invoke(Self.setArguments(flat, deviceId: deviceId, jsonPath: setPath), jsonPath: setPath, what: "set")
        let getPath = Self.temporaryPath()
        let json = try invoke(Self.getArguments(deviceId: deviceId, jsonPath: getPath), jsonPath: getPath, what: "get")
        guard let json, let reported = Self.deviceOrientation(fromJSON: json) else {
            throw DeviceBackendError.orientationCommandFailed(
                message: "devicectl device orientation get wrote no readable orientation"
            )
        }
        return reported
    }

    @discardableResult
    private func invoke(_ arguments: [String], jsonPath: String, what: String) throws -> Data? {
        let result = run(arguments, jsonPath)
        guard result.status == 0 else {
            let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DeviceBackendError.orientationCommandFailed(
                message: "devicectl device orientation \(what) exited \(result.status): \(reason)"
            )
        }
        return result.json
    }
}
