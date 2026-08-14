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
        // Restore before the next serialized test. `restoreSharedSim`
        // uses the track's `bootstatus` gate rather than stopping at
        // `.booted`, because a device in between fails the next HID test on
        // an unconnected mach port. Subsystem-specific readiness checks
        // still apply on top of it.
        //
        // Failing here fails *this* test, rather than leaving it green on a
        // device it broke. Later tests can't be relied on to report it: a
        // half-booted device still satisfies `singleBootedDevice()`, and
        // this one may run last.
        #expect(
            restoreSharedSim(handle),
            """
            failed to restore the shared sim to a usable state after \
            shutting it down.
            """
        )
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
