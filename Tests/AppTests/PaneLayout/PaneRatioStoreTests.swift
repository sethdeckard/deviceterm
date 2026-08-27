// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Testing

@testable import App

@MainActor
struct PaneRatioStoreTests {
    @Test
    func ratiosRoundTripByPath() {
        let store = PaneRatioStore()
        #expect(store.ratios(forPath: [0]) == nil)
        store.setRatios([0.3, 0.7], forPath: [0])
        #expect(store.ratios(forPath: [0]) == [0.3, 0.7])
        store.clearRatios()
        #expect(store.ratios(forPath: [0]) == nil)
    }

    @Test
    func remapRatiosRekeysTheStoreOntoTheNewTree() {
        // The mapping itself is pinned in PaneRatioRemapTests; this is
        // the surface `reconcile` calls, so it only has to show the
        // store adopting the result.
        let terminal = PaneSlot.terminal(TerminalPaneID(value: 1))
        let sim = PaneSlot.sim(udid: "udid-a")
        let store = PaneRatioStore()
        store.setRatios([0.71, 0.29], forPath: [])

        store.remapRatios(
            from: .split(axis: .horizontal, children: [.leaf(terminal), .leaf(sim)], extents: [1, 1]),
            to: .split(axis: .horizontal, children: [.leaf(sim), .leaf(terminal)], extents: [1, 1])
        )

        #expect(store.ratios(forPath: []) == [0.29, 0.71])
    }

    @Test
    func splitRegistryMapsBothWays() {
        let store = PaneRatioStore()
        let split = NSSplitView()
        store.register(split, path: [1, 0])
        #expect(store.path(for: split) == [1, 0])
        #expect(store.splitIdentifier(forPath: [1, 0]) == ObjectIdentifier(split))
        #expect(store.splitIdentifier(forPath: [9]) == nil)
        store.clearSplits()
        #expect(store.path(for: split) == nil)
    }

    @Test
    func withApplyGuardIsReentrantSafe() {
        let store = PaneRatioStore()
        #expect(store.isApplying == false)
        store.withApply {
            #expect(store.isApplying)
            // Nested apply must not clear the guard when the inner call
            // returns: only the outermost restore drops it.
            store.withApply {
                #expect(store.isApplying)
            }
            #expect(store.isApplying)
        }
        #expect(store.isApplying == false)
    }
}
