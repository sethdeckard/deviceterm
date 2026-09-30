// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import Testing

/// PendingPaneReducer: the placeholder pane's phase machine as a pure
/// function. No view, no daemon: the transitions a pending pane can take
/// (its attach threw or was refused as not booted, the user pressed Boot, or
/// a fresh attach started) are pinned here.
struct PendingPaneReducerTests {
    @Test
    func attachFailedMovesToFailedWithMessage() {
        #expect(
            PendingPaneReducer.reduce(.attaching, .attachFailed("device is locked"))
                == .failed("device is locked")
        )
    }

    @Test
    func retriedReturnsToAttaching() {
        #expect(PendingPaneReducer.reduce(.failed("boom"), .retried) == .attaching)
    }

    @Test
    func attachFailedOverwritesAnEarlierMessage() {
        #expect(
            PendingPaneReducer.reduce(.failed("old"), .attachFailed("new"))
                == .failed("new")
        )
    }

    @Test
    func aNotBootedRefusalOffersBoot() {
        #expect(
            PendingPaneReducer.reduce(.attaching, .deviceNotBooted("iPhone Duo is shut down"))
                == .notBooted("iPhone Duo is shut down")
        )
    }

    @Test
    func bootStartedMovesANotBootedPaneToBooting() {
        #expect(PendingPaneReducer.reduce(.notBooted("down"), .bootStarted) == .booting)
    }

    @Test("Boot is ignored outside notBooted", arguments: [
        PendingPanePhase.attaching,
        PendingPanePhase.failed("boom"),
        PendingPanePhase.booting
    ])
    func bootStartedLeavesOtherPhasesAlone(phase: PendingPanePhase) {
        #expect(PendingPaneReducer.reduce(phase, .bootStarted) == phase)
    }

    @Test
    func anAcceptedBootReattaches() {
        #expect(PendingPaneReducer.reduce(.booting, .retried) == .attaching)
    }

    @Test
    func aRefusedBootFails() {
        #expect(PendingPaneReducer.reduce(.booting, .attachFailed("no")) == .failed("no"))
    }

    @Test("settled failures", arguments: [
        (PendingPanePhase.failed("boom"), true),
        (PendingPanePhase.notBooted("down"), true),
        (PendingPanePhase.attaching, false),
        (PendingPanePhase.booting, false)
    ])
    func onlyAFinishedAttachIsASettledFailure(phase: PendingPanePhase, settled: Bool) {
        #expect(phase.isSettledFailure == settled)
    }
}

/// The placeholder's shown label: the caller's name, then a looked-up device
/// name, then a target-prefix stub.
@MainActor
struct PendingPaneLabelTests {
    private func pending(displayName: String?, resolvedLabel: String?) -> PendingPaneState {
        var state = PendingPaneState(
            id: PendingPaneID(value: 1),
            target: .sim(udid: "1d464fbe-56ba-4a49-8d73-277a7e8a0e92"),
            displayName: displayName
        )
        state.resolvedLabel = resolvedLabel
        return state
    }

    @Test
    func theCallersNameWins() {
        #expect(PendingPaneViewController.label(for: pending(displayName: "Desk", resolvedLabel: "Looked")) == "Desk")
    }

    @Test
    func aLookedUpNameReplacesTheStub() {
        #expect(PendingPaneViewController.label(for: pending(displayName: nil, resolvedLabel: "Looked")) == "Looked")
    }

    @Test
    func theStubRemainsWithoutEither() {
        #expect(PendingPaneViewController.label(for: pending(displayName: nil, resolvedLabel: nil)) == "Sim 1d464fbe")
    }
}
