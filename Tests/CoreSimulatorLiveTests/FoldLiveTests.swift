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

/// A node's label and its frame in the tree's own layout space.
private typealias LabelledFrame = (label: String, frame: CGRect)

/// Every framed node's label and frame, in the tree's own layout space.
private func framedLabels(_ node: [String: Any], into out: inout [LabelledFrame]) {
    let label = node["label"] as? String ?? node["identifier"] as? String ?? ""
    if let frame = node["frame"] as? [String: Any],
        let originX = frame["x"] as? Double, let originY = frame["y"] as? Double,
        let width = frame["w"] as? Double, let height = frame["h"] as? Double,
        width > 0, height > 0 {
        out.append((label, CGRect(x: originX, y: originY, width: width, height: height)))
    }
    for child in node["children"] as? [[String: Any]] ?? [] { framedLabels(child, into: &out) }
}

/// The second of two reads a second apart whose framed labels and frames
/// match, with those rows, or nil if no pair matches in 15 tries. Settings
/// animates for seconds after launch, and a verdict judged against a tree
/// still moving is worthless either way.
private func settledRows(_ accessibility: SimAccessibility) -> (tree: [String: Any], rows: [LabelledFrame])? {
    func rows(_ tree: [String: Any]) -> [LabelledFrame] {
        var out: [LabelledFrame] = []
        framedLabels(tree, into: &out)
        return out
    }
    func signature(_ rows: [LabelledFrame]) -> String {
        rows.map { "\($0.label)|\($0.frame)" }.joined(separator: "\n")
    }
    for _ in 0..<15 {
        guard let first = try? accessibility.frontmostTree() else { continue }
        Thread.sleep(forTimeInterval: 1.0)
        guard let second = try? accessibility.frontmostTree() else { continue }
        let settled = rows(second)
        if signature(rows(first)) == signature(settled) { return (second, settled) }
    }
    return nil
}

private func simctl(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl"] + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
}

@Test(.enabled(if: bootedDeviceIsFoldable()))
func aTapReachesWhicheverPanelIsLit() async throws {
    // Indigo's fixed digitizer target reaches only one of a foldable's panels,
    // and which one changes from boot to boot, so a pass on one panel says
    // nothing about the other. This taps both, in one pane, across folds made
    // through that pane, so a stale panel or orientation fails here as well.
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let restore = try SimBackendAcquirer.acquireFromBridge(udid: booted.udid).backend
    try await withHingeRestored(restore) {
        let coordinator = PaneCoordinator()
        let session = UUID()
        let pane = try await coordinator.createSim(sessionId: session, udid: booted.udid)
        // The pane is closed on both paths and awaited, not deferred, for the
        // same reason `withHingeRestored` awaits its restore.
        let outcome: Result<[String], any Error>
        do {
            outcome = .success(try await tapEachPosture(
                coordinator,
                pane: pane.paneId,
                session: session,
                udid: booted.udid
            ))
        } catch {
            outcome = .failure(error)
        }
        _ = await coordinator.close(paneId: pane.paneId, as: .session(session), mode: .detach)
        let missed = try outcome.get()
        #expect(missed.isEmpty, "taps that opened nothing: \(missed.joined(separator: "; "))")
    }
}

/// Tap a Settings row at each posture and return the taps that opened nothing.
private func tapEachPosture(
    _ coordinator: PaneCoordinator,
    pane: UUID,
    session: UUID,
    udid: String
) async throws -> [String] {
    // Back to the cover after the inner panel, so the binding is tested
    // after moving in each direction.
    var missed: [String] = []
    for angle in [0.0, 180.0, 0.0] {
        try await coordinator.fold(paneId: pane, as: .session(session), degrees: angle)
        try await Task.sleep(nanoseconds: 6_000_000_000)
        try simctl(["terminate", udid, "com.apple.Preferences"])
        try simctl(["launch", udid, "com.apple.Preferences"])
        try await Task.sleep(nanoseconds: 4_000_000_000)

        let display = try SimDisplayHandle.handle(forUDID: udid)
        try display.start { _ in }
        try await Task.sleep(nanoseconds: 500_000_000)
        let lit = display.boundScreenID
        display.stop()
        let accessibility = try SimAccessibility.client(forUDID: udid)
        accessibility.displayID = lit

        let before = try #require(settledRows(accessibility), "at \(angle)°, Settings never settled")
        let geometry = try #require(AXSweep.geometry(fromTree: before.tree))
        try #require(
            !before.rows.contains { $0.label == "BackButton" },
            "at \(angle)°, Settings relaunched onto a pushed page"
        )
        // A row Settings lists on either panel. The inner panel shows a
        // sidebar beside a detail page, and its tree carries only part of
        // the sidebar, so the cover's first choice is not always present.
        let row = try #require(
            ["Accessibility", "About", "Dictionary"].lazy.compactMap { name in
                before.rows.first { $0.label == name }
            }.first,
            "at \(angle)°, no known row on screen: \(before.rows.map(\.label))"
        )
        // A third of the way along the row, off the diagonal, so a rotation
        // applied wrongly lands somewhere else instead of on the same row.
        let displayed = CGPoint(
            x: (row.frame.minX + row.frame.width * 0.3) / geometry.viewer.width,
            y: row.frame.midY / geometry.viewer.height
        )
        try await coordinator.tap(
            paneId: pane,
            as: .session(session),
            x: displayed.x,
            y: displayed.y
        )
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let after = settledRows(accessibility)?.rows ?? []
        if !after.contains(where: { $0.label == "BackButton" }) {
            missed.append("\(angle)° screen \(lit): \(row.label) at \(displayed)")
        }
    }
    return missed
}
