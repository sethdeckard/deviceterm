// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// The hinge reader against a real device. Part of the deliberate
// `make test-live` track, and the only automated check that `HingeMonitor`
// parses what `devicectl` actually prints: `HingeMonitorTests` drives a fake
// reader, so a format change would leave it green.
//
// What this cannot cover is the point of the feature, which is a fold made in
// Device Hub moving the slider on screen. That stays a hand-check.

private func bootedDeviceIsFoldable() -> Bool {
    guard let booted = try? SimDeviceHandle.singleBootedDevice() else { return false }
    return SimDisplayHandle.deviceHasMultiplePanels(udid: booted.udid)
}

@Test(.enabled(if: bootedDeviceIsFoldable()))
func theMonitorReportsAHingeItDidNotDrive() async throws {
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let backend = try SimBackendAcquirer.acquireFromBridge(udid: booted.udid).backend
    try #require(backend.capabilities.fold, "a two-panel device must advertise fold")

    let readings = HingeReadings()
    let monitor = HingeMonitor(udid: booted.udid) { readings.append($0) }
    monitor.start()
    defer { monitor.stop() }

    // The first line carries the current angle, so the reader proves itself
    // before anything moves.
    #expect(
        await readings.settles(),
        "the monitor read nothing at all; `devicectl` output may have changed shape"
    )

    // Two angles, so a pass cannot come from the device already sitting where
    // it was asked to go. The monitor has no knowledge of this path: it reads
    // the device, which is why a Device Hub fold reaches it the same way.
    //
    // Wrapped so the hinge goes back to where the track's clean-slate boot had
    // it however this ends. A fold that throws here would otherwise leave a
    // shared device part-open for every test after this one.
    try await withHingeRestored(backend) {
        for angle in [45.0, 135.0] {
            try await backend.fold(
                toDegrees: angle,
                generation: backend.currentInputGeneration()
            )
            #expect(
                await readings.reaches(angle),
                "monitor never reported \(angle); saw \(readings.values())"
            )
        }
    }
}

/// Angles the monitor reported, collected off its queue.
private final class HingeReadings: @unchecked Sendable {
    private let lock = NSLock()
    private var angles: [Double] = []

    func append(_ angle: Double) {
        lock.lock()
        angles.append(angle)
        lock.unlock()
    }

    func values() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return angles
    }

    /// Wait for any reading at all.
    func settles() async -> Bool {
        await poll { !self.values().isEmpty }
    }

    /// Wait for `angle` to be reported. The device reports whole degrees on a
    /// driven fold, so this compares exactly rather than within a tolerance.
    func reaches(_ angle: Double) async -> Bool {
        await poll { self.values().contains(angle) }
    }

    /// Polls rather than sleeping a fixed span: the reader samples at 10 Hz and
    /// the guest takes its own time to move.
    private func poll(_ condition: @escaping () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}
