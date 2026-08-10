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
