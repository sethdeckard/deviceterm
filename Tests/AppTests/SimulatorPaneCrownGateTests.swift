// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimulatorPaneCrownGateTests: pins the family gate on the
// `simulatorPaneDidCrown` delegate callback. SimulatorContentView
// routes every bare-scroll event into the delegate; the VC drops
// it for non-watch sims (a scroll over a phone / pad / tv pane has
// no semantic mapping) and forwards to the VM's crown intent
// for watch sims, which the daemon turns into a Digital Crown
// rotation.
//
// Without the gate, a bare scroll over any sim would silently fire
// a `pane.input.crown` against a device that doesn't have a crown
// (the daemon would log + reject), but the user-visible symptom is
// "scrolling on a phone sim sometimes nudges the watch sim in
// another tab if I had one open." The gate is the source-of-truth
// barrier.

@testable import App
import CoreGraphics
import DaemonProtocol
import Testing

@MainActor
struct SimulatorPaneCrownGateTests {
    private func makeViewController(
        family: String
    ) -> (SimulatorPaneViewController, FakeDaemonClient) {
        let pane = SimPaneState(
            paneId: "p1",
            udid: "U",
            displayName: "device",
            family: family
        )
        let fake = FakeDaemonClient()
        let viewController = SimulatorPaneViewController(
            simPane: pane,
            daemonClient: fake
        )
        return (viewController, fake)
    }

    @Test
    func watchPaneForwardsCrownToDaemon() async {
        let (viewController, fake) = makeViewController(family: "watch")
        viewController.simulatorPaneDidCrown(delta: 2.5)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(fake.crownCalls.count == 1)
        #expect(fake.crownCalls.first?.paneId == "p1")
        #expect(fake.crownCalls.first?.delta == 2.5)
    }

    @Test(
        "non-watch families drop crown silently",
        arguments: [
        "phone",
        "pad",
        "tv",
        "unknown"
        ]
        )
    func nonWatchFamilyDropsCrown(family: String) async {
        let (viewController, fake) = makeViewController(family: family)
        viewController.simulatorPaneDidCrown(delta: 5.0)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(fake.crownCalls.isEmpty)
    }
}
