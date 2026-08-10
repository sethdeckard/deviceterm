// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreSimulatorBridge
import Foundation
import Testing

// Live swipe regression cover. Asserting "the SwiftUI DragGesture
// recognizer fired" needs a watchOS host app carrying a probe view;
// `Tests/Manual/watchos-checklist.md` ("Swipe Behavior Across SwiftUI Gestures")
// specifies that reproducer and records the 9-variant matrix already
// run against it. What these tests catch is the layer below the
// recognizer: the regression class "swipe dispatch through the Indigo
// digitizer itself started failing", e.g. a SimulatorKit selector goes
// away or the bridge translation breaks. Per HIDClientLiveTests'
// precedent the bridge can't observe whether the touch *landed* on a
// recognizer, so these tests assert only that every per-frame send
// returned without throwing.
//
// Two scenarios:
//
//   1. The default multi-step interpolation pattern (durationMs=200
//      → 12 intermediate sends + a final tapUp), exercising
//      `PaneCoordinator.swipe`'s "real drag" wire path against a
//      live digitizer.
//   2. The sub-frame collapse pattern (durationMs=16 → steps=1, the
//      `SwipeAck.dispatched == .tap` case the daemon surfaces),
//      verifies the daemon's short-duration path bridges cleanly
//      regardless of the dispatch-as-tap classification.

private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

@Test
func swipeAsInterpolatedTapDownsSucceeds() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let client = try SimHIDClient.client(forUDID: booted.udid)
    // Vertical bottom-to-top "swipe up" pattern; common gesture in
    // every iOS / watchOS UI (scroll, dismiss, app switcher). 12
    // intermediate steps over 200ms matches the daemon's default
    // (`GestureTiming` math at 16ms-per-frame). Coords are normalized
    // [0,1], which is what `SimHIDClient.tapDown` expects.
    let fromPoint = CGPoint(x: 0.5, y: 0.8)
    let toPoint = CGPoint(x: 0.5, y: 0.2)
    let steps = 12
    try client.tapDown(at: fromPoint)
    for step in 1...steps {
        // ~60Hz cadence, what `PaneCoordinator.swipe` paces. Brief
        // sleep gives the digitizer time to actually accept the
        // event; sending all 12 instantly produces a different
        // wire profile than a real drag.
        Thread.sleep(forTimeInterval: 0.016)
        let progress = Double(step) / Double(steps)
        let interpolatedX = fromPoint.x + (toPoint.x - fromPoint.x) * progress
        let interpolatedY = fromPoint.y + (toPoint.y - fromPoint.y) * progress
        try client.tapDown(at: CGPoint(x: interpolatedX, y: interpolatedY))
    }
    try client.tapUp(at: toPoint)
}

@Test
func swipeAtSubFrameDurationCollapsesToSingleStepWithoutThrowing() throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let client = try SimHIDClient.client(forUDID: booted.udid)
    // The daemon surfaces this case in its response as
    // `SwipeAck.dispatched == .tap`: `GestureTiming.steps` clamps
    // to `max(1, clamped/16)`, so any `durationMs < 32` collapses
    // to a single step. The resulting wire is
    // `tapDown(start) → tapDown(end) → tapUp(end)`, indistinguishable
    // from a fast tap. Verify the bridge accepts the collapsed shape
    // cleanly, so agents using the `dispatched: tap` path get a clean
    // dispatch even when their requested duration was too short for
    // a real drag.
    let fromPoint = CGPoint(x: 0.4, y: 0.4)
    let toPoint = CGPoint(x: 0.6, y: 0.6)
    try client.tapDown(at: fromPoint)
    try client.tapDown(at: toPoint)
    try client.tapUp(at: toPoint)
}
