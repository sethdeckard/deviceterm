// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

/// The per-subscriber queue that bounds the 60Hz lane.
///
/// Production access to the channel runs under `PaneCoordinator`; these direct
/// tests preserve the same safety invariant by staying single-task and
/// non-concurrent. Park and resume need two parties and so cannot be
/// tested here without breaking that promise; they are covered through the
/// coordinator in `PaneCoordinatorBackendTests`.
struct ConflatingEventChannelTests {
    private let paneId = UUID()

    private func drain(_ channel: ConflatingEventChannel) -> [PaneEvent] {
        var events: [PaneEvent] = []
        while let event = channel.take() { events.append(event) }
        return events
    }

    private func sequences(_ events: [PaneEvent]) -> [UInt64] {
        events.compactMap {
            if case let .surfaceChanged(_, sequence) = $0 { return sequence }
            return nil
        }
    }

    private func states(_ events: [PaneEvent]) -> [PaneLifecycle] {
        events.compactMap {
            if case let .stateChanged(_, state) = $0 { return state }
            return nil
        }
    }

    @Test
    func aBurstOfFramesCollapsesToTheNewest() {
        // The whole point: a consumer that stops reading accumulates one
        // surface notice, not one per frame.
        let channel = ConflatingEventChannel()
        for sequence in UInt64(1) ... 100 {
            channel.send(.surfaceChanged(paneId: paneId, sequence: sequence))
        }
        #expect(channel.pendingCount == 1)
        #expect(sequences(drain(channel)) == [100])
        #expect(channel.conflatedSurfaceCount == 99)
    }

    @Test
    func lifecycleEventsSurviveAFrameBurst() {
        // Lifecycle transitions are lossless: frame conflation has to
        // preserve both `.booting` and `.rendering`.
        let channel = ConflatingEventChannel()
        channel.send(.stateChanged(paneId: paneId, state: .booting))
        for sequence in UInt64(1) ... 50 {
            channel.send(.surfaceChanged(paneId: paneId, sequence: sequence))
        }
        channel.send(.stateChanged(paneId: paneId, state: .rendering))
        channel.send(.orientationChanged(paneId: paneId, orientation: .landscapeLeft))
        let events = drain(channel)
        #expect(states(events) == [.booting, .rendering])
        #expect(sequences(events) == [50])
    }

    @Test
    func aNewerFrameMovesBehindWhateverArrivedBeforeIt() {
        // Conflation folds frames; it must not reorder them. Keeping the
        // replaced frame's old slot would put sequence 2 ahead of a rotation
        // it actually came after, and the consumer would render the newest
        // framebuffer against the previous orientation.
        let channel = ConflatingEventChannel()
        channel.send(.surfaceChanged(paneId: paneId, sequence: 1))
        channel.send(.orientationChanged(paneId: paneId, orientation: .landscapeLeft))
        channel.send(.surfaceChanged(paneId: paneId, sequence: 2))
        let events = drain(channel)
        guard events.count == 2 else {
            Issue.record("expected one frame notice to survive, not two")
            return
        }
        if case .orientationChanged = events[0] {} else {
            Issue.record("the rotation preceded the surviving frame")
        }
        #expect(sequences([events[1]]) == [2])
    }

    @Test
    func theSubscribeReplayKeepsItsOrder() {
        // `subscribe` replays state, then orientation, then the current frame.
        // A reader has to see them that way or it renders a frame against the
        // wrong orientation.
        let channel = ConflatingEventChannel()
        channel.send(.stateChanged(paneId: paneId, state: .rendering))
        channel.send(.orientationChanged(paneId: paneId, orientation: .landscapeRight))
        channel.send(.surfaceChanged(paneId: paneId, sequence: 7))
        let events = drain(channel)
        #expect(events.count == 3)
        if case .stateChanged = events[0] {} else { Issue.record("state first") }
        if case .orientationChanged = events[1] {} else { Issue.record("orientation second") }
        #expect(sequences([events[2]]) == [7])
    }

    @Test(arguments: [PaneLifecycle.shutdown, .failed])
    func aTerminalStateDropsAPendingFrameAndSealsTheSlot(state: PaneLifecycle) {
        // A terminal state removes any pending frame notice and rejects
        // later ones. Lifecycle and orientation events still queue.
        let channel = ConflatingEventChannel()
        channel.send(.surfaceChanged(paneId: paneId, sequence: 1))
        channel.send(.stateChanged(paneId: paneId, state: state))
        channel.send(.surfaceChanged(paneId: paneId, sequence: 2))
        let events = drain(channel)
        #expect(states(events) == [state])
        #expect(sequences(events).isEmpty)
        #expect(channel.isSealed)
    }

    @Test
    func finishingLeavesQueuedEventsReadable() {
        // The teardown paths unsubscribe and then read what the pane
        // published, so a close cannot discard the queue.
        let channel = ConflatingEventChannel()
        channel.send(.stateChanged(paneId: paneId, state: .rendering))
        channel.send(.surfaceChanged(paneId: paneId, sequence: 3))
        channel.finish()
        #expect(drain(channel).count == 2)
        #expect(channel.isFinished)
    }

    @Test
    func aFinishedChannelAcceptsNothingFurther() {
        let channel = ConflatingEventChannel()
        channel.finish()
        channel.send(.stateChanged(paneId: paneId, state: .rendering))
        #expect(channel.pendingCount == 0)
    }

    @Test
    func aStalledConsumerKeepsOneFrameWhileStateEventsQueue() {
        // The stalled-consumer shape the unit exists for: unbounded frames in,
        // one frame plus every lifecycle event pending.
        let channel = ConflatingEventChannel()
        for step in UInt64(1) ... 20 {
            channel.send(.surfaceChanged(paneId: paneId, sequence: step))
            channel.send(.orientationChanged(paneId: paneId, orientation: .portrait))
        }
        #expect(channel.pendingCount == 21)
        let events = drain(channel)
        #expect(sequences(events) == [20])
        #expect(events.count == 21)
    }
}
