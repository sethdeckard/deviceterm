// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
@testable import Daemon
import Foundation
import Testing

// Driving a foldable's hinge, against a booted sim. Deliberate
// `make test-live` track.
//
// The helper these exercise is compiled on demand rather than shipped. They
// cover that build when the cache is empty; the cache is persistent and
// keyed on source and toolchain, so a run that finds it warm reuses the
// binary and proves only that the cached path is still executable.

private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

/// Whether the booted device vends a second panel, which is what the fold
/// capability is set from.
private func bootedDeviceIsFoldable() -> Bool {
    guard let booted = try? SimDeviceHandle.singleBootedDevice() else { return false }
    return SimDisplayHandle.deviceHasMultiplePanels(udid: booted.udid)
}

/// The hinge angle `devicectl` reports, or nil when it reports none. Read
/// through Apple's own tool rather than our own path, so a fold that only
/// looked like it landed cannot pass.
private func reportedHingeAngle(udid: String) -> Double? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
        "devicectl", "device", "motion", "hinge-angle", "--device", udid, "--timeout", "5"
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    // "• +0.000s : Angle:130.0°  Mech:130.0° …"
    guard let line = text.split(separator: "\n").first(where: { $0.contains("Angle:") }),
        let after = line.range(of: "Angle:") else { return nil }
    let digits = line[after.upperBound...].prefix { $0.isNumber || $0 == "." || $0 == " " }
    return Double(digits.trimmingCharacters(in: .whitespaces))
}

@Test
func theHelperBuildsAndCachesForThisToolchain() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let builder = FoldHelperBuilder()
    let binary = try builder.helperBinary()
    #expect(FileManager.default.isExecutableFile(atPath: binary))
    // The second call must not rebuild: the path is keyed on the source and
    // toolchain, so a fold per second cannot become a compile per second.
    #expect(try builder.helperBinary() == binary)
}

@Test(.enabled(if: bootedDeviceIsFoldable()))
func foldingMovesTheHingeToTheRequestedAngle() async throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    // Straight from the bridge rather than through the actor: this needs a
    // real backend for one device, not the acquirer's sharing and lifecycle.
    let backend = try SimBackendAcquirer.acquireFromBridge(udid: booted.udid).backend
    try #require(backend.capabilities.fold, "a two-panel device must advertise fold")

    // There and back, so a pass cannot come from the device already sitting
    // at the angle asked for.
    for angle in [130.0, 0.0] {
        try await backend.fold(
            toDegrees: angle,
            generation: backend.currentInputGeneration()
        )
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let reported = try #require(
            reportedHingeAngle(udid: booted.udid),
            "devicectl reported no hinge angle"
        )
        #expect(reported == angle, "asked for \(angle), device reports \(reported)")
    }
}

@Test(.enabled(if: !bootedDeviceIsFoldable()))
func aSinglePanelDeviceRefusesToFold() async throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let backend = try SimBackendAcquirer.acquireFromBridge(udid: booted.udid).backend
    #expect(!backend.capabilities.fold)
    do {
        try await backend.fold(
            toDegrees: 90,
            generation: backend.currentInputGeneration()
        )
        Issue.record("a single-panel device accepted a fold")
    } catch let error as DeviceBackendError {
        guard case .unsupportedFold = error else {
            Issue.record("refused with \(error) rather than unsupportedFold")
            return
        }
    }
}
