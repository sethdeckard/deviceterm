// SPDX-License-Identifier: GPL-3.0-or-later
//
// Restoring the shared sim after a test drives it through a shutdown.
//
// The whole live target shares one booted device that `make test-live`
// provisions, so a test that shuts it down owes every later test a device
// in the state the track promised. Two tests do that deliberately, to
// observe an out-of-band shutdown reaching the notifier and the pane
// registry.

import CoreSimulatorBridge
import Foundation

/// Boot the shared sim and wait for `simctl bootstatus` to complete.
///
/// CoreSimulator can report `.booted` while its system app is still
/// starting, so a test that runs next and drives HID hits an unconnected
/// mach port, which looks like a defect in the code under test.
///
/// `bootstatus` is a floor, not a guarantee of readiness for every
/// subsystem. Tests with their own probe (`AccessibilityLiveTests` polls
/// for the AX server) still need it.
///
/// `simctl bootstatus` is the same gate `scripts/test-live.sh` uses before
/// it runs the track, so a sim restored here matches the one the track
/// hands to the first test.
///
/// Returns whether the device came back. **Check it.** A caller that
/// discards this can leave a destructive test green on an unusable
/// device, and later tests won't reliably catch it: a half-booted device
/// still satisfies `singleBootedDevice()`, so they fail on whatever they
/// touch first rather than on the missing sim.
func restoreSharedSim(_ handle: SimDeviceHandle) -> Bool {
    guard (try? handle.boot()) != nil else { return false }
    return waitForSystemApp(udid: handle.udid, timeout: bootTimeout)
}

/// The track's boot budget, so a device slow enough to need a raised
/// `DEVICETERM_LIVE_BOOT_TIMEOUT` gets the same allowance when it is
/// restored mid-run as it got when the track booted it. Hard-coding a
/// shorter one here would fail a restore on a device the track itself
/// admitted (a cold runtime's first boot, or a watch).
private var bootTimeout: TimeInterval {
    let raw = ProcessInfo.processInfo.environment["DEVICETERM_LIVE_BOOT_TIMEOUT"]
    guard let raw, let seconds = TimeInterval(raw), seconds > 0 else { return 240 }
    return seconds
}

/// Run `simctl bootstatus`, which returns once the device has booted and
/// its system app is up. Returns false at the timeout so the caller can
/// fail without hanging the track.
private func waitForSystemApp(udid: String, timeout: TimeInterval) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl", "bootstatus", udid]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return false
    }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    if process.isRunning {
        process.terminate()
        return false
    }
    return process.terminationStatus == 0
}
