// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Testing

@testable import App

@Suite("Pane auto-fit decision")
struct PaneAutoFitDecisionTests {
    private let targetA = PaneTarget.sim(udid: "A")
    private let targetB = PaneTarget.sim(udid: "B")
    private let slotA = PaneSlot.sim(udid: "A")
    private let slotB = PaneSlot.sim(udid: "B")
    private let placeholder = PendingPaneID(value: 1)

    /// A flat horizontal split of `slots`, which is all these rules need:
    /// they compare parent paths, and nesting is expressed by passing a
    /// nested tree explicitly.
    private func row(_ slots: [PaneSlot]) -> PaneNode {
        .split(
            axis: .horizontal,
            children: slots.map { .leaf($0) },
            extents: slots.map { _ in 1 }
        )
    }

    @Test
    func aSimNewToTheTabIsFitted() {
        let outcome = PaneAutoFitDecision.advance(
            previous: [:],
            tree: row([.terminal(TerminalPaneID(value: 1)), slotA]),
            pendingTargets: [:]
        )
        #expect(outcome.needsFit == [slotA])
        #expect(outcome.paths == [targetA: [1]])
    }

    @Test
    func anOrdinaryAttachIsFittedWhenItsPlaceholderSwapsIn() {
        // The ordinary attach reaches the swap through the same
        // `.pending` → `.sim` transition a re-attach does. A first attach
        // has no carried-forward path, which is the whole of what tells the
        // two apart, so it must still take its initial fit.
        let terminal = PaneSlot.terminal(TerminalPaneID(value: 1))
        let attaching = PaneAutoFitDecision.advance(
            previous: [:],
            tree: row([terminal, .pending(placeholder)]),
            pendingTargets: [placeholder: targetA]
        )
        #expect(attaching.needsFit.isEmpty)
        #expect(attaching.paths.isEmpty)

        let mounted = PaneAutoFitDecision.advance(
            previous: attaching.paths,
            tree: row([terminal, slotA]),
            pendingTargets: [:]
        )
        #expect(mounted.needsFit == [slotA])
    }

    @Test
    func aReattachedSimKeepsItsSizing() {
        // The reboot / helper-restart round trip. The placeholder carries
        // the pane's last mounted path, so the sim returning to the same
        // parent is not fitted and the proportions the user dragged survive.
        let terminal = PaneSlot.terminal(TerminalPaneID(value: 1))
        let attaching = PaneAutoFitDecision.advance(
            previous: [targetA: [1]],
            tree: row([terminal, .pending(placeholder)]),
            pendingTargets: [placeholder: targetA]
        )
        #expect(attaching.needsFit.isEmpty)
        #expect(attaching.paths == [targetA: [1]])

        let mounted = PaneAutoFitDecision.advance(
            previous: attaching.paths,
            tree: row([terminal, slotA]),
            pendingTargets: [:]
        )
        #expect(mounted.needsFit.isEmpty)
    }

    @Test
    func aPlaceholderThatMovesDoesNotRewriteThePaneSHistory() {
        // A sibling closing compacts the placeholder's parent, so the
        // placeholder's own path changes while the pane it stands for has
        // not moved anywhere yet. Carrying the last mounted path is what
        // keeps the comparison honest: the pane left [1, 0] and returns to
        // [1], a different parent, so it does need the fit.
        let terminal = PaneSlot.terminal(TerminalPaneID(value: 1))
        let nested = PaneNode.split(
            axis: .horizontal,
            children: [
                .leaf(terminal),
                .split(
                    axis: .vertical,
                    children: [.leaf(slotB), .leaf(.pending(placeholder))],
                    extents: [1, 1]
                )
            ],
            extents: [1, 1]
        )
        let attaching = PaneAutoFitDecision.advance(
            previous: [targetA: [1, 1], targetB: [1, 0]],
            tree: nested,
            pendingTargets: [placeholder: targetA]
        )
        #expect(attaching.paths[targetA] == [1, 1])

        // simB closes; the vertical split compacts and the placeholder
        // becomes the parent's direct child at [1].
        let compacted = PaneAutoFitDecision.advance(
            previous: attaching.paths,
            tree: row([terminal, .pending(placeholder)]),
            pendingTargets: [placeholder: targetA]
        )
        #expect(compacted.paths[targetA] == [1, 1])  // still carried, not [1]

        let mounted = PaneAutoFitDecision.advance(
            previous: compacted.paths,
            tree: row([terminal, slotA]),
            pendingTargets: [:]
        )
        #expect(mounted.needsFit == [slotA])
    }

    @Test
    func aSiblingShuffleIsNotFitted() {
        // A new sim inserted ahead of this one moves its index but not its
        // parent. Re-fitting here cascades divider moves across every sim
        // under the split until one collapses to its minimum thickness.
        let outcome = PaneAutoFitDecision.advance(
            previous: [targetA: [1]],
            tree: row([.terminal(TerminalPaneID(value: 1)), slotB, slotA]),
            pendingTargets: [:]
        )
        #expect(outcome.needsFit == [slotB])
    }

    @Test
    func aSimDraggedIntoANewSubSplitIsFitted() {
        // [1] → [1, 0] is a different parent, so the extent it had says
        // nothing about the extent it now gets.
        let tree = PaneNode.split(
            axis: .horizontal,
            children: [
                .leaf(.terminal(TerminalPaneID(value: 1))),
                .split(
                    axis: .vertical,
                    children: [.leaf(slotA), .leaf(slotB)],
                    extents: [1, 1]
                )
            ],
            extents: [1, 1]
        )
        let outcome = PaneAutoFitDecision.advance(
            previous: [targetA: [1]],
            tree: tree,
            pendingTargets: [:]
        )
        #expect(outcome.needsFit.contains(slotA))
    }

    @Test
    func aClosedPaneIsForgottenAndStartsOverIfItComesBack() {
        // Closing drops the leaf with no placeholder behind it, so the
        // target has left the tab. Attaching it again later is a first
        // attach, not a continuation.
        let terminal = PaneSlot.terminal(TerminalPaneID(value: 1))
        let closed = PaneAutoFitDecision.advance(
            previous: [targetA: [1]],
            tree: row([terminal, slotB]),
            pendingTargets: [:]
        )
        #expect(closed.paths[targetA] == nil)

        let back = PaneAutoFitDecision.advance(
            previous: closed.paths,
            tree: row([terminal, slotB, slotA]),
            pendingTargets: [:]
        )
        #expect(back.needsFit.contains(slotA))
    }

    @Test
    func aDevicePlaceholderNeitherFitsNorCarriesASimSPath() {
        // A device attach runs the same placeholder swap. Nothing fits a
        // device, and its target is not a sim's, so it neither arms a fit
        // nor carries a sim's path.
        let terminal = PaneSlot.terminal(TerminalPaneID(value: 1))
        let outcome = PaneAutoFitDecision.advance(
            previous: [:],
            tree: row([terminal, .pending(placeholder), .device(deviceId: "D")]),
            pendingTargets: [placeholder: .device(deviceId: "D2")]
        )
        #expect(outcome.needsFit.isEmpty)
        #expect(outcome.paths.isEmpty)
    }

    @Test
    func twoPanesRecoveringAtOnceBothKeepTheirSizing() {
        // A helper restart swaps every mounted sim for a placeholder and
        // back. Neither returning pane is fitted, which is what leaves a
        // hand-arranged pair (a watch stacked over a phone, dragged narrow)
        // exactly as the user left it.
        let terminal = PaneSlot.terminal(TerminalPaneID(value: 1))
        let second = PendingPaneID(value: 2)
        let attaching = PaneAutoFitDecision.advance(
            previous: [targetA: [1], targetB: [2]],
            tree: row([terminal, .pending(placeholder), .pending(second)]),
            pendingTargets: [placeholder: targetA, second: targetB]
        )
        #expect(attaching.paths == [targetA: [1], targetB: [2]])

        let mounted = PaneAutoFitDecision.advance(
            previous: attaching.paths,
            tree: row([terminal, slotA, slotB]),
            pendingTargets: [:]
        )
        #expect(mounted.needsFit.isEmpty)
    }
}
