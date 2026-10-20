// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// DeviceCtlOrientationTests: the argv `devicectl device orientation` is given,
// the `get` payload it answers with, and how a run's outcome becomes the
// orientation reported or an error. The fixture is a sanitized capture of a
// `get` after `set faceUp` on an iPhone Simulator; the fake runner avoids
// subprocesses.

private func loadFixture() throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: "devicectl-orientation-get", withExtension: "json")
    )
    return try Data(contentsOf: url)
}

/// Records each run and replays canned results in order.
private final class Runs: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [DeviceCtlRun]
    private var recorded: [[String]] = []

    init(_ queued: [DeviceCtlRun]) {
        self.queued = queued
    }

    func run(_ arguments: [String], _ jsonPath: String) -> DeviceCtlRun {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(arguments)
        return queued.isEmpty ? DeviceCtlRun(status: 0, json: nil, stderr: "") : queued.removeFirst()
    }

    func arguments() -> [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// The message an `orientationCommandFailed` carries, or nil when `body`
/// returns or throws anything else.
private func failureMessage(_ body: () throws -> String) -> String? {
    do {
        _ = try body()
        return nil
    } catch let DeviceBackendError.orientationCommandFailed(message) {
        return message
    } catch {
        return nil
    }
}

@Test("set passes the wire name, which devicectl accepts as it is", arguments: [
    (FlatOrientation.faceUp, "faceUp"),
    (.faceDown, "faceDown")
])
func setArguments(flat: FlatOrientation, value: String) {
    #expect(DeviceCtlOrientation.setArguments(flat, deviceId: "U1", jsonPath: "/tmp/o.json") == [
        "devicectl", "device", "orientation", "set", "--device", "U1", value,
        "--json-output", "/tmp/o.json", "--quiet"
    ])
}

@Test
func getArguments() {
    #expect(DeviceCtlOrientation.getArguments(deviceId: "U1", jsonPath: "/tmp/o.json") == [
        "devicectl", "device", "orientation", "get", "--device", "U1",
        "--json-output", "/tmp/o.json", "--quiet"
    ])
}

@Test
func theGetPayloadReportsTheDeviceOrientation() throws {
    #expect(DeviceCtlOrientation.deviceOrientation(fromJSON: try loadFixture()) == "faceUp")
}

@Test
func theGetPayloadReportsTheUprightOrientationWhileFlat() throws {
    // The fixture lies face up; the upright orientation it was last in stands.
    #expect(DeviceCtlOrientation.uprightOrientation(fromJSON: try loadFixture()) == .portrait)
}

@Test("an upright orientation that isn't one of the four reads as nothing", arguments: [
    #"{"result":{"deviceOrientation":"faceUp"}}"#,
    #"{"result":{"deviceOrientation":"faceUp","deviceOrientationNonFlat":"unknown"}}"#
])
func anUnusableUprightOrientationReadsAsNothing(json: String) {
    #expect(DeviceCtlOrientation.uprightOrientation(fromJSON: Data(json.utf8)) == nil)
}

@Test
func aPayloadWithoutTheFieldReportsNothing() {
    #expect(DeviceCtlOrientation.deviceOrientation(fromJSON: Data(#"{"result":{}}"#.utf8)) == nil)
}

@Test
func setReadsBackWhatTheDeviceReports() throws {
    let runs = Runs([
        DeviceCtlRun(status: 0, json: nil, stderr: ""),
        DeviceCtlRun(status: 0, json: try loadFixture(), stderr: "")
    ])
    let orientation = DeviceCtlOrientation(run: runs.run)

    #expect(try orientation.set(.faceUp, deviceId: "U1") == "faceUp")
    // The set, then a separate get: the reading is the device's, not an echo
    // of the request.
    #expect(runs.arguments().map { $0[3] } == ["set", "get"])
}

@Test
func aFailedSetThrowsWithDevicectlsReasonAndSkipsTheGet() {
    let runs = Runs([DeviceCtlRun(status: 1, json: nil, stderr: "  not supported\n")])
    let orientation = DeviceCtlOrientation(run: runs.run)

    #expect(failureMessage { try orientation.set(.faceDown, deviceId: "U1") }
        == "devicectl device orientation set exited 1: not supported")
    #expect(runs.arguments().count == 1)
}

@Test
func aGetWithNoReadablePayloadThrows() {
    let runs = Runs([
        DeviceCtlRun(status: 0, json: nil, stderr: ""),
        DeviceCtlRun(status: 0, json: nil, stderr: "")
    ])
    let orientation = DeviceCtlOrientation(run: runs.run)

    #expect(failureMessage { try orientation.set(.faceUp, deviceId: "U1") }
        == "devicectl device orientation get wrote no readable orientation")
}
