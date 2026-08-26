// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

/// DiscoveryDecision: which owned+booted sims get a pane, and how
/// the "handled" memory is pruned.
struct DiscoveryDecisionTests {
    private func device(_ udid: String) -> DeviceListEntry {
        DeviceListEntry(
            udid: udid,
            name: "iPhone-\(udid)",
            state: "Booted",
            ownedBySession: "S"
        )
    }

    @Test
    func attachesUnhandledUnmountedSims() {
        let decision = DiscoveryDecision.decide(
            ownedBooted: [device("A"), device("B")],
            handled: ["A"],
            attaching: [],
            mounted: []
        )
        #expect(decision.toAttach.map(\.udid) == ["B"])
        #expect(decision.updatedHandled == ["A"])
    }

    @Test
    func prunesHandledForDepartedSims() {
        // X is no longer booted+owned, so it's dropped from handled.
        let decision = DiscoveryDecision.decide(
            ownedBooted: [device("A"), device("B")],
            handled: ["A", "X"],
            attaching: [],
            mounted: []
        )
        #expect(decision.updatedHandled == ["A"])
        #expect(decision.toAttach.map(\.udid) == ["B"])
    }

    @Test
    func skipsMountedAndAttachingSims() {
        let decision = DiscoveryDecision.decide(
            ownedBooted: [device("A"), device("B"), device("C")],
            handled: [],
            attaching: ["B"],
            mounted: ["C"]
        )
        #expect(decision.toAttach.map(\.udid) == ["A"])
    }

    @Test
    func emptyWhenNothingBooted() {
        let decision = DiscoveryDecision.decide(
            ownedBooted: [],
            handled: ["A"],
            attaching: [],
            mounted: []
        )
        #expect(decision.toAttach.isEmpty)
        #expect(decision.updatedHandled.isEmpty)
    }
}
