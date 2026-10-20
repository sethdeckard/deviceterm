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
        /// The last of the four upright orientations, which `get` keeps
        /// reporting while the device lies flat. Absent from `set`.
        let deviceOrientationNonFlat: String?
    }

    private static let productionRunner: Runner = { arguments, jsonPath in
        DeviceCtlRun.spawn(arguments: arguments, jsonPath: jsonPath, timeout: commandTimeout)
    }

    /// How long a command may take. A warm `get` answers in a tenth of a
    /// second; right after a boot it can wait minutes, and a read that long is
    /// worth less than one retried later.
    static let commandTimeout: TimeInterval = 5

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

    /// The upright orientation a `get` payload reports, whether or not the
    /// device is lying flat. Nil when it's absent or not one of the four.
    static func uprightOrientation(fromJSON data: Data) -> Orientation? {
        guard let name = try? JSONDecoder().decode(Output.self, from: data).result.deviceOrientationNonFlat else {
            return nil
        }
        return Orientation(rawValue: name)
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

    /// The device's upright orientation, its physical attitude rather than
    /// the orientation the interface shows. Nil when `devicectl` fails or
    /// reports none of the four. Blocks for a process run.
    func uprightOrientation(deviceId: String) -> Orientation? {
        let path = Self.temporaryPath()
        guard let json = try? invoke(Self.getArguments(deviceId: deviceId, jsonPath: path), jsonPath: path, what: "get")
        else { return nil }
        return Self.uprightOrientation(fromJSON: json)
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
