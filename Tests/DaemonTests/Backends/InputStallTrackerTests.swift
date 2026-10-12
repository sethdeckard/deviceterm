// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

// A stalled pane under a held finger times out once a second for as long as
// the stall lasts, so the tracker reports edges only.

private let origin = ContinuousClock.now

@Test
func aFirstTimeoutBeginsAStallAndLaterOnesStaySilent() {
    var tracker = InputStallTracker()
    #expect(tracker.noteTimeout(operation: "tapDown", at: origin) == .began(operation: "tapDown"))
    #expect(tracker.noteTimeout(operation: "tapUp", at: origin + .seconds(1)) == nil)
    #expect(tracker.noteTimeout(operation: "tapUp", at: origin + .seconds(2)) == nil)
    #expect(tracker.isStalled)
    #expect(tracker.episodes == 1)
}

@Test
func aCompletedSendEndsTheStallWithItsDurationAndTimeouts() {
    var tracker = InputStallTracker()
    _ = tracker.noteTimeout(operation: "tapDown", at: origin)
    _ = tracker.noteTimeout(operation: "tapUp", at: origin + .seconds(1))
    let ended = tracker.noteCompleted(operation: "tapDown", at: origin + .seconds(5))
    #expect(ended == .ended(operation: "tapDown", duration: .seconds(5), timeouts: 2, refused: 0))
    #expect(!tracker.isStalled)
}

@Test
func completedSendsWithNoStallReportNothing() {
    var tracker = InputStallTracker()
    #expect(tracker.noteCompleted(operation: "tapDown", at: origin) == nil)
    #expect(tracker.episodes == 0)
}

@Test
func eachStallCountsAsItsOwnEpisodeWithItsOwnTimeouts() {
    var tracker = InputStallTracker()
    _ = tracker.noteTimeout(operation: "tapDown", at: origin)
    _ = tracker.noteTimeout(operation: "tapDown", at: origin + .seconds(1))
    _ = tracker.noteCompleted(operation: "tapDown", at: origin + .seconds(2))
    #expect(tracker.noteTimeout(operation: "keyDown", at: origin + .seconds(3)) == .began(operation: "keyDown"))
    let ended = tracker.noteCompleted(operation: "keyUp", at: origin + .seconds(4))
    #expect(ended == .ended(operation: "keyUp", duration: .seconds(1), timeouts: 1, refused: 0))
    #expect(tracker.episodes == 2)
}

@Test
func refusalsCountOnlyInsideAStall() {
    var tracker = InputStallTracker()
    tracker.noteRefused()
    _ = tracker.noteTimeout(operation: "tapDown", at: origin)
    tracker.noteRefused()
    tracker.noteRefused()
    let ended = tracker.noteCompleted(operation: "tapUp", at: origin + .seconds(3))
    #expect(ended == .ended(operation: "tapUp", duration: .seconds(3), timeouts: 1, refused: 2))
    // A new stall starts its own count.
    _ = tracker.noteTimeout(operation: "tapDown", at: origin + .seconds(4))
    let next = tracker.noteCompleted(operation: "tapDown", at: origin + .seconds(5))
    #expect(next == .ended(operation: "tapDown", duration: .seconds(1), timeouts: 1, refused: 0))
}

@Test("only the bridge's send timeout counts as a stall", arguments: [
    ("CoreSimulatorBridge.SimHIDClient", 49, true),
    // A NULL build: nothing was sent, so it says nothing about whether sends complete.
    ("CoreSimulatorBridge.SimHIDClient", 48, false),
    // A dead port is a disconnect, not a stall.
    ("SimulatorKit.SimDeviceLegacyHIDClient.HIDError", 3, false),
    ("CoreSimulatorBridge.SimPurpleHID", 49, false)
])
func classifiesSendTimeouts(domain: String, code: Int, isTimeout: Bool) {
    let error = NSError(domain: domain, code: code)
    #expect(SimDeviceBackend.isSendTimeout(error) == isTimeout)
}
