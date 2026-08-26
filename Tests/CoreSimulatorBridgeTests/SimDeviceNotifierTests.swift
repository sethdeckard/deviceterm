// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import Foundation
import Testing

// Hermetic + lightweight integration coverage for the set-level
// notification wrapper.
//
// The wrapper is intentionally thin: it constructs a registration
// against the default device set, retains the registration ID,
// dispatches the bridge's typed `CSBNotifierEvent` to a Swift
// closure, and unregisters on cancel. The hermetic surface
// (enum + payload type stability) lives here; the actual
// notification-arrival smoke is in `CoreSimulatorLiveTests` since
// it needs a live sim to transition state.

// MARK: - Pure: enum stability

@Test
func notifierEventKindRawValuesAreStable() {
    // The two cases pin the wire shape. Adding cases later is
    // fine, but renumbering would break callers (DeviceCoordinator
    // switches on these in production).
    #expect(CSBNotifierEventKind.stateChanged.rawValue == 0)
    #expect(CSBNotifierEventKind.other.rawValue == 1)
}

@Test
func notifierEventDefaultStateIsUnknown() {
    // A fresh event (zero-init via NSObject) reads its state
    // fields as `.unknown`. Pins the bridge's "absent ⇒ Unknown"
    // contract; DeviceCoordinator's switch handles unknown by
    // dropping the event, so this must not silently start
    // mapping onto `.booted` etc.
    let event = CSBNotifierEvent()
    #expect(event.newState == .unknown)
    #expect(event.previousState == .unknown)
    #expect(event.udid.isEmpty)
    #expect(event.rawName.isEmpty)
}

// MARK: - Integration: registration lifecycle
//
// Gated on probe().ok the same as the rest of the bridge tests.
// These tests only exercise register-then-cancel on the live
// framework; they don't wait for an actual notification (that's
// the live-sim track's job).

private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func defaultNotifierRegistersAgainstLiveDeviceSet() throws {
    let queue = DispatchQueue(label: "deviceterm.test.notifier", qos: .userInitiated)
    let notifier = try CSBDeviceNotifier.defaultNotifier(queue: queue) { _ in
        // No-op: we're testing the bridge's registration path,
        // not delivery. Live delivery is exercised in
        // `SimDeviceNotifierLiveTests`.
    }
    // Bridge returns a non-nil handle on success. If we got here,
    // CoreSimulator accepted the registration and gave us a
    // non-zero token (the impl returns nil + error on token 0).
    notifier.cancel()
}

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func cancelIsIdempotent() throws {
    let queue = DispatchQueue(label: "deviceterm.test.notifier.idempotent", qos: .userInitiated)
    let notifier = try CSBDeviceNotifier.defaultNotifier(queue: queue) { _ in }
    // Two cancels back-to-back: the second is a no-op. Without
    // this, daemon shutdown plus a stray dealloc would
    // double-unregister and CoreSimulator would log a warning
    // (or in older revisions, crash).
    notifier.cancel()
    notifier.cancel()
}
