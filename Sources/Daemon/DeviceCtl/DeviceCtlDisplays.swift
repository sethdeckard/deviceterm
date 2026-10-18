// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// `xcrun devicectl device info displays`, read for which of a foldable's
/// panels iOS has lit.
///
/// Its `active` flag changes when iOS decides to swap panels, before the old
/// panel has finished fading out. Nothing the bridge can read in-process
/// tells the two panels apart that early: a panel's pixels keep their last
/// frame through the fade, and the measured screen-state properties do not
/// identify which panel is active.
/// The cost is a process per read, about half a second.
///
/// Structured like `DeviceCtlOrientation`: pure argv and parse halves, tested
/// without spawning, behind an injectable runner that blocks for the run.
struct DeviceCtlDisplays: Sendable {
    /// Runs `xcrun` with the arguments and returns what `devicectl`
    /// produced, including the `--json-output` file at the path given.
    typealias Runner = @Sendable (_ arguments: [String], _ jsonPath: String) -> DeviceCtlRun

    /// What one read says about the lit panel.
    enum ActivePanel: Equatable, Sendable {
        /// Exactly one panel is active: the one with this display id, the
        /// same number `SimScreenProperties.screenID` and `simctl io
        /// --display` use.
        case panel(UInt32)
        /// The read worked but no single panel is active.
        case undecided
        /// `devicectl` failed or wrote nothing readable.
        case unavailable
    }

    // Only the fields read.
    private struct Output: Decodable {
        let result: Result
    }

    private struct Result: Decodable {
        let displays: [Display]
    }

    private struct Display: Decodable {
        let displayId: UInt32
        let active: Bool
    }

    private let run: Runner

    init(run: Runner? = nil) {
        self.run = run ?? { DeviceCtlRun.spawn(arguments: $0, jsonPath: $1) }
    }

    // MARK: Pure

    /// The argv after `xcrun`.
    static func arguments(deviceId: String, jsonPath: String) -> [String] {
        [
            "devicectl", "device", "info", "displays", "--device", deviceId,
            "--json-output", jsonPath, "--quiet"
        ]
    }

    /// The lit panel a `--json-output` payload reports.
    static func activePanel(fromJSON data: Data) -> ActivePanel {
        guard let output = try? JSONDecoder().decode(Output.self, from: data) else { return .unavailable }
        let active = output.result.displays.filter(\.active)
        guard active.count == 1, let only = active.first else { return .undecided }
        return .panel(only.displayId)
    }

    private static func temporaryPath() -> String {
        NSTemporaryDirectory()
            + "deviceterm-devicectl-displays-\(ProcessInfo.processInfo.processIdentifier)-"
            + UUID().uuidString + ".json"
    }

    // MARK: Command

    /// Read which panel `deviceId` has lit. Blocks for the run.
    func activePanel(deviceId: String) -> ActivePanel {
        let path = Self.temporaryPath()
        let result = run(Self.arguments(deviceId: deviceId, jsonPath: path), path)
        guard result.status == 0, let json = result.json else { return .unavailable }
        return Self.activePanel(fromJSON: json)
    }
}
