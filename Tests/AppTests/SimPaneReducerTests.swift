// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sim pane state machine transitions: pure-logic tests.

@testable import App
import DaemonProtocol
import Testing

struct SimPaneReducerTests {
    @Test
    func firstSurfacePromotesBootingToRendering() {
        #expect(SimPaneReducer.reduce(.booting, .surfaceAttached) == .rendering)
    }

    @Test
    func surfaceDoesNotRegressNonBooting() {
        #expect(SimPaneReducer.reduce(.rendering, .surfaceAttached) == .rendering)
        #expect(SimPaneReducer.reduce(.shutdown, .surfaceAttached) == .shutdown)
        #expect(
            SimPaneReducer.reduce(
            .failed("x"),
            .surfaceAttached
        ) == .failed("x")
            )
    }

    @Test
    func lifecycleBootingOnlyWalksBackFromRendering() {
        #expect(SimPaneReducer.reduce(.rendering, .lifecycle(.booting)) == .booting)
        #expect(SimPaneReducer.reduce(.booting, .lifecycle(.booting)) == .booting)
        #expect(SimPaneReducer.reduce(.shutdown, .lifecycle(.booting)) == .shutdown)
    }

    @Test
    func lifecycleTransitions() {
        #expect(SimPaneReducer.reduce(.booting, .lifecycle(.rendering)) == .rendering)
        #expect(SimPaneReducer.reduce(.rendering, .lifecycle(.shutdown)) == .shutdown)
        #expect(
            SimPaneReducer.reduce(
            .rendering,
            .lifecycle(.failed)
        ) == .failed("daemon reported pane failure")
            )
    }

    @Test
    func subscriptionFailureCarriesMessage() {
        #expect(
            SimPaneReducer.reduce(
            .rendering,
            .subscriptionFailed("boom")
        ) == .failed("boom")
            )
    }
}
