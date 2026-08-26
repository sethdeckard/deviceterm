// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

/// Which markers a pill carries, and their order.
///
/// The order is the part worth pinning. `markers` appends in order and the
/// strip mounts the list as given, so swapping the two appends would put the
/// lock first and nothing in the code would object. The last case is what
/// catches that.
@Suite("tab pill markers")
struct TabMarkerDecisionTests {
    /// Role and protection are independent, so all four combinations are
    /// reachable. The last row is the one that pins the order: protection
    /// sits closer to the title, so toggling it never shifts the wand.
    @Test("role and protection are independent axes", arguments: [
        (SessionRole.agent, false, [TabPillMarker]()),
        (SessionRole.automation, false, [TabPillMarker.automation]),
        (SessionRole.agent, true, [TabPillMarker.protection]),
        (SessionRole.automation, true, [TabPillMarker.automation, .protection])
    ])
    func marksEachCombination(
        role: SessionRole,
        isProtected: Bool,
        expected: [TabPillMarker]
    ) {
        #expect(
            TabMarkerDecision.markers(
                role: role,
                isEffectivelyProtected: isProtected
            ) == expected
        )
    }

    @Test("a tab hidden but not yet committed is marked")
    func pendingProtectionMarks() {
        // The marker follows `isEffectivelyProtected`, which is true for
        // `.pendingProtected` as well as `.protected`. A protect the daemon
        // has not confirmed, and an unprotect that failed, both leave the tab
        // hidden, and the strip has to say so. Reading `isProtected` instead
        // would leave a hidden tab unmarked.
        var tab = TabState(
            id: TabID(value: 1),
            terminals: [
                TerminalPaneState(
                    id: TerminalPaneID(value: 1),
                    sessionId: "S1",
                    capability: "C1"
                )
            ],
            simPanes: []
        )
        tab.protectionState = .pendingProtected
        #expect(tab.isProtected == false)
        #expect(tab.isEffectivelyProtected)
        #expect(
            TabMarkerDecision.markers(
                role: tab.role,
                isEffectivelyProtected: tab.isEffectivelyProtected
            ) == [.protection]
        )
    }
}
