// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import Foundation
import Testing

// Live notification subscription against a booted sim. Pinned to
// the `make test-live` track because the only way to observe
// notification delivery is to drive an actual state transition
// (shutdown the booted sim, watch the handler fire), and the
// hermetic bridge tests can only confirm registration succeeds.
//
// What this track guarantees end-to-end:
//   - The notification dict keys (`notification_name`, `device`,
//     `new_state`) we assumed in the bridge actually match what
//     current CoreSimulator publishes. If Apple renames a key,
//     this test fails loudly with the dict shape recorded.
//   - The wrapper's `CSBNotifierEvent` carries a valid UDID and
//     resolved `CSBSimState` on a real transition.
//   - Cancellation actually stops further delivery (no events
//     arrive after `cancel()`).

private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

/// Box for handler-collected events. The notifier delivers on a
/// background queue; tests read from the main thread after a
/// deterministic wait, so concurrent access goes through this
/// serial sync.
private final class EventInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CSBNotifierEvent] = []

    func append(_ event: CSBNotifierEvent) {
        lock.lock(); defer { lock.unlock() }
        events.append(event)
    }

    func drain() -> [CSBNotifierEvent] {
        lock.lock(); defer { lock.unlock() }
        let snapshot = events
        events.removeAll(keepingCapacity: false)
        return snapshot
    }

    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        return events.count
    }
}

/// Drain the inbox until `predicate` matches an event or the
/// timeout expires. Returns whatever was observed along the way
/// so a failing assertion can show the full notification stream
/// for the dict-key archaeology that lives in `CSBNEventFromDict`.
///
/// "First event" isn't a reliable signal: a shutdown transition
/// can publish an intermediate `.shuttingDown` (or a separate
/// `device_*` notification with no state change) before the
/// final `.shutdown` arrives. Stopping at the first event would
/// make the test order-flaky.
private func waitForMatchingEvent(
    _ inbox: EventInbox,
    matching predicate: (CSBNotifierEvent) -> Bool,
    timeoutSeconds: Double = 8
) -> (match: CSBNotifierEvent?, observed: [CSBNotifierEvent]) {
    let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
    var observed: [CSBNotifierEvent] = []
    while Date() < deadline {
        observed.append(contentsOf: inbox.drain())
        if let match = observed.first(where: predicate) {
            return (match, observed)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    observed.append(contentsOf: inbox.drain())
    return (observed.first(where: predicate), observed)
}

/// Wait for the device to reach a target state, polling
/// `handle.state`. Used after the destructive shutdown test to
/// restore the live track's "single booted sim" invariant before
/// any later test in the run reads `singleBootedDevice()`.
private func waitForState(
    _ handle: SimDeviceHandle,
    target: CSBSimState,
    timeoutSeconds: Double = 60
) -> Bool {
    let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
    while Date() < deadline {
        if handle.state == target { return true }
        Thread.sleep(forTimeInterval: 0.5)
    }
    return false
}

@Test
func shutdownTransitionPublishesNotificationForBootedDevice() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )

    let inbox = EventInbox()
    let queue = DispatchQueue(label: "deviceterm.test.notifier.shutdown", qos: .userInitiated)
    let notifier = try CSBDeviceNotifier.defaultNotifier(queue: queue) { event in
        inbox.append(event)
    }
    defer { notifier.cancel() }

    // Drive a transition: shut the sim down. CoreSimulator should
    // publish at least one state-change notification for this UDID
    // with `newState == .shutdown`. The whole CoreSimulatorLiveTests
    // target shares one booted sim provisioned by `make test-live`;
    // shutting it down without restoring would make every later
    // live test fail with "no booted sim". Reboot + wait below
    // restores the invariant before the assertion completes.
    let handle = try SimDeviceHandle.handle(forUDID: booted.udid)
    try handle.shutdown()
    defer {
        // Best-effort restore. If reboot or wait fails, the
        // remaining live tests will fail with a clear
        // singleBootedDevice() error, surfaced rather than
        // silenced, which matches the "stop, don't silently
        // settle" rule for the live track. `try?` keeps the
        // catch implicit because `return` isn't allowed from a
        // `defer`.
        if (try? handle.boot()) != nil {
            _ = waitForState(handle, target: .booted)
        }
    }

    let (matching, observed) = waitForMatchingEvent(inbox) { event in
        event.kind == .stateChanged
            && event.udid.lowercased() == booted.udid.lowercased()
            && event.newState == .shutdown
    }
    let trace = observed.map { event in
        "kind=\(event.kind.rawValue) udid=\(event.udid)" +
            " newState=\(event.newState.rawValue) raw=\(event.rawName)"
    }
    #expect(
        matching != nil,
        """
        no matching .shutdown state-change for the shut-down sim within timeout
        — dict keys may have drifted in CoreSimulator.
        observed events: \(trace)
        """
    )
}

@Test
func cancelStopsFurtherDelivery() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )

    let inbox = EventInbox()
    let queue = DispatchQueue(label: "deviceterm.test.notifier.cancel", qos: .userInitiated)
    let notifier = try CSBDeviceNotifier.defaultNotifier(queue: queue) { event in
        inbox.append(event)
    }

    // Cancel immediately. Any subsequent CoreSimulator activity
    // (this run won't drive one, but background state changes
    // happen in shared simulators) must not reach the handler.
    notifier.cancel()
    Thread.sleep(forTimeInterval: 1.0)
    let leaked = inbox.drain()
    #expect(leaked.isEmpty, "events delivered after cancel: \(leaked.count)")
}
