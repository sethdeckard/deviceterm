// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import Testing

@Suite
@MainActor
struct SimulatorFrameDemandTests {
    @Test
    func hiddenPaneKeepsLifecycleAndResumesFrames() async {
        let fake = FakeDaemonClient()
        let model = SimulatorPaneViewModel(
            paneId: "p1", daemonClient: fake, udid: "U", displayName: "Phone", family: "phone"
        )
        model.setFrameDemand(false)
        model.start()
        #expect(await wait { fake.subscribeFrameRequests == [false] })
        fake.lastPaneEventContinuation?.yield(
            .stateChanged(StateChangedEvent(paneId: "p1", state: .rendering))
        )
        #expect(await wait { model.state == .rendering })
        model.setFrameDemand(true)
        #expect(await wait { fake.subscribeFrameRequests == [false, true] })
        model.setFrameDemand(false)
        model.setFrameDemand(true)
        model.setFrameDemand(false)
        #expect(await wait { fake.subscribeFrameRequests == [false, true, false] })
        await model.close()
        model.setFrameDemand(true)
        #expect(fake.subscribeFrameRequests == [false, true, false])
    }

    @Test(arguments: [
        (true, false, false, true),
        (true, true, false, false),
        (false, false, false, false),
        (true, false, true, false)
    ])
    func windowDemand(visible: Bool, minimized: Bool, hidden: Bool, expected: Bool) {
        #expect(SimulatorFrameDemandDecision.isWindowEligible(
            visible: visible, minimized: minimized, applicationHidden: hidden
        ) == expected)
    }

    private func wait(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
}
