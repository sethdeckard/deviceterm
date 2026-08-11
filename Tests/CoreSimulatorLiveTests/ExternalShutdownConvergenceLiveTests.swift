// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
@testable import Daemon
import Foundation
import Testing

// A sim shut down by something outside deviceterm must still retire its
// panes, end to end through the real CoreSimulator notification.
//
// This is the surface nothing else covers. Quitting Apple's Simulator.app
// shuts down every sim it attached to, and a `simctl shutdown` from a
// stock terminal never reaches the shim: in both cases deviceterm issued
// no shutdown of its own, so the only signal is the set-level notifier.
// If its convergence hook doesn't reach the pane registry, frames simply
// stop arriving and the pane keeps rendering its last one behind menus
// that no longer do anything, leaving the pane visibly frozen.
//
// Live track because a CoreSimulator notification can't be faked: the
// hermetic tests in `DeviceCoordinatorNotificationTests` pin that
// `noteExternalShutdown` calls the converger, and this pins that a real
// device transition reaches it.

private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

/// Poll `handle` until it reports `target` or the timeout expires.
/// Returns whether it got there. Mirrors the wait in
/// `SimDeviceNotifierLiveTests`, which restores the shared sim the same
/// way after driving a transition through it.
@discardableResult
private func waitForState(
    _ handle: SimDeviceHandle,
    target: CSBSimState,
    timeout: TimeInterval = 60
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if handle.state == target { return true }
        Thread.sleep(forTimeInterval: 0.25)
    }
    return handle.state == target
}

/// Poll `coordinator` until the pane reports `.shutdown` or the timeout
/// expires. Returns the last state observed so a failure can say what
/// the pane was actually stuck on.
private func waitForPaneShutdown(
    coordinator: PaneCoordinator,
    sessionId: UUID,
    timeout: TimeInterval = 10
) async -> PaneLifecycle? {
    let deadline = Date().addingTimeInterval(timeout)
    var last: PaneLifecycle?
    while Date() < deadline {
        last = await coordinator.panesForSession(sessionId).first?.state
        if last == .shutdown { return last }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return last
}

@Test
func externalShutdownDrivesAnAttachedPaneToShutdown() async throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )

    let paneCoordinator = PaneCoordinator()
    let sessionId = UUID()
    _ = try await paneCoordinator.createSim(sessionId: sessionId, udid: booted.udid)
    // Resolved before the subscription so a failed lookup can't strand a
    // live notifier registration: everything that throws between the
    // subscribe and the awaited unsubscribe leaves one behind.
    let handle = try SimDeviceHandle.handle(forUDID: booted.udid)

    let deviceCoordinator = DeviceCoordinator()
    try await deviceCoordinator.subscribeToCoreSimulator(
        paneShutdownConverger: { udid in
            await paneCoordinator.markPanesShutdown(forUDID: udid)
        }
    )

    // Shut the sim down *without* going through the daemon, which is what
    // Simulator.app quitting looks like from here. The whole live target
    // shares one booted sim provisioned by `make test-live`, so restore it
    // afterwards: any boot-dependent test that runs later needs it.
    try handle.shutdown()
    defer {
        // Best-effort restore. Failures are ignored here and may cause
        // later boot-dependent tests to report "no booted sim"; test order
        // isn't guaranteed, so a failure can also go unnoticed. `boot()`
        // returns once CoreSimulator accepts the intent, so wait for the
        // state to land or the next test races it.
        // Weaker than the track's `simctl bootstatus` clean-slate boot,
        // which also waits for the system app: a device can read `.booted`
        // while SpringBoard is still starting, so a following test driving
        // HID or AX may see a sluggish device for a moment.
        if (try? handle.boot()) != nil {
            waitForState(handle, target: .booted)
        }
    }

    let observed = await waitForPaneShutdown(
        coordinator: paneCoordinator,
        sessionId: sessionId
    )
    // Awaited rather than deferred: `defer` can't await, and a
    // fire-and-forget Task would let the registration outlive the test
    // and deliver into a coordinator nobody is reading.
    await deviceCoordinator.unsubscribeFromCoreSimulator()
    #expect(
        observed == .shutdown,
        """
        pane did not converge after an out-of-band sim shutdown \
        (last observed state: \(observed.map(\.rawValue) ?? "no pane")). \
        The shutdown did not reach the pane registry through the \
        notification and convergence path.
        """
    )
}
