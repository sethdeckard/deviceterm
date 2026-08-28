// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

/// The fallback ladder a tab walks when it comes back into view: the
/// remembered pane, then the primary terminal, then whatever is left.
/// Pure, so every rung is checked without a window.
@MainActor
struct PaneFocusRestoreDecisionTests {
    private let primary = TerminalPaneID(value: 1)
    private let secondTerminal = TerminalPaneID(value: 2)

    private var threePanes: [PaneSlot] {
        [.terminal(primary), .sim(udid: "U-A"), .terminal(secondTerminal)]
    }

    @Test
    func prefersTheRememberedPane() {
        let slot = PaneFocusRestoreDecision.slot(
            remembered: .sim(udid: "U-A"),
            primaryTerminal: primary,
            mounted: Set(threePanes),
            order: threePanes
        )
        #expect(slot == .sim(udid: "U-A"))
    }

    @Test
    func fallsBackToPrimaryWhenTheRememberedPaneIsGone() {
        // The pane was closed while the tab sat in the background, so
        // the memory names a pane with no controller behind it.
        let mounted: Set<PaneSlot> = [.terminal(primary), .terminal(secondTerminal)]
        let slot = PaneFocusRestoreDecision.slot(
            remembered: .sim(udid: "U-GONE"),
            primaryTerminal: primary,
            mounted: mounted,
            order: [.terminal(primary), .terminal(secondTerminal)]
        )
        #expect(slot == .terminal(primary))
    }

    @Test
    func fallsBackToPrimaryWhenNothingIsRemembered() {
        let slot = PaneFocusRestoreDecision.slot(
            remembered: nil,
            primaryTerminal: primary,
            mounted: Set(threePanes),
            order: threePanes
        )
        #expect(slot == .terminal(primary))
    }

    @Test
    func fallsBackToTheFirstMountedPaneWhenThePrimaryHasNoController() {
        // A terminal's provisioning can throw, which leaves the tab
        // holding a primary terminal that never got a view controller.
        // Focusing the sim beats focusing nothing.
        let mounted: Set<PaneSlot> = [.sim(udid: "U-A"), .terminal(secondTerminal)]
        let slot = PaneFocusRestoreDecision.slot(
            remembered: nil,
            primaryTerminal: primary,
            mounted: mounted,
            order: threePanes
        )
        #expect(slot == .sim(udid: "U-A"))
    }

    @Test
    func thirdTierFollowsDisplayOrderNotSetOrder() {
        // `mounted` is a Set, whose iteration order is unspecified and
        // varies between runs. Resolving the last rung from it directly
        // would focus an arbitrary pane; the supplied display order
        // makes it the first visible pane.
        let mounted: Set<PaneSlot> = [
            .sim(udid: "U-A"),
            .sim(udid: "U-B"),
            .sim(udid: "U-C")
        ]
        let order: [PaneSlot] = [.sim(udid: "U-C"), .sim(udid: "U-B"), .sim(udid: "U-A")]
        for _ in 0..<20 {
            let slot = PaneFocusRestoreDecision.slot(
                remembered: nil,
                primaryTerminal: primary,
                mounted: mounted,
                order: order
            )
            #expect(slot == .sim(udid: "U-C"))
        }
    }

    @Test
    func returnsNilWhenNothingIsMounted() {
        // Nothing to focus means leave the responder chain alone rather
        // than clearing it.
        let slot = PaneFocusRestoreDecision.slot(
            remembered: .sim(udid: "U-A"),
            primaryTerminal: primary,
            mounted: [],
            order: threePanes
        )
        #expect(slot == nil)
    }
}
