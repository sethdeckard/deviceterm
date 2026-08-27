// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import MirrorPipeline

/// The disconnect-versus-failure call, which decides whether a pane that lost
/// its mirror waits for the device to come back or surfaces an error.
///
/// It lives here rather than in the lifecycle suite because the receive loop
/// reaches the disconnect verdict only after a session has produced frames,
/// and producing a frame needs a device to negotiate with. This is the half of
/// that decision testable without one.
struct MirrorRunHistoryTests {
    @Test
    func aRunThatNeverMirroredGivesUpAsAFailure() {
        // The attach that never worked: re-attaching lands in the same place,
        // so the pane must show the error rather than retry forever.
        var history = MirrorRunHistory()
        for _ in 0..<5 { history.record(framesProduced: 0) }
        #expect(!history.everProduced)
        #expect(history.giveUpTermination == .failed)
    }

    @Test
    func aRunThatMirroredGivesUpAsADisconnect() {
        var history = MirrorRunHistory()
        history.record(framesProduced: 120)
        #expect(history.giveUpTermination == .disconnected)
    }

    @Test
    func laterEmptySessionsDoNotEraseThatItMirrored() {
        // The shape a real unplug takes: one session streams, then every
        // restart comes up empty until the budget runs out. Reading only the
        // last session would classify it as a failure and strand the pane.
        var history = MirrorRunHistory()
        history.record(framesProduced: 120)
        for _ in 0..<5 { history.record(framesProduced: 0) }
        #expect(history.everProduced)
        #expect(history.giveUpTermination == .disconnected)
    }

    @Test
    func aFreshHistoryHasMirroredNothing() {
        // A run that gives up before any session finishes still has to answer,
        // and "never mirrored" is the answer that doesn't invent a reconnect.
        #expect(MirrorRunHistory().giveUpTermination == .failed)
    }
}
