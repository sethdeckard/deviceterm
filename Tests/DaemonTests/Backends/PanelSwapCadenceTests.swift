// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Testing

private let quick = PanelSwapCadence.Step.wait(nanoseconds: PanelSwapCadence.quickIntervalNanoseconds)
private let patient = PanelSwapCadence.Step.wait(nanoseconds: PanelSwapCadence.patientIntervalNanoseconds)

@Test("panel swap cadence", arguments: [
    // A rebind ends the search in either phase.
    (1, true, true, PanelSwapCadence.Step.stop),
    (40, true, true, PanelSwapCadence.Step.stop),
    // The quick phase keeps polling whatever the bound panel reads, because
    // the old panel can still be lit just after the notice.
    (1, false, false, quick),
    (29, false, true, quick),
    // Past it, a dark bound panel keeps the search going at the slower pace,
    // and a lit one ends it.
    (30, false, true, patient),
    (500, false, true, patient),
    (30, false, false, PanelSwapCadence.Step.stop),
    (31, false, false, PanelSwapCadence.Step.stop)
])
func pacesTheSearchForAPanelSwap(attempts: Int, rebound: Bool, swapPending: Bool, expected: PanelSwapCadence.Step) {
    #expect(PanelSwapCadence.next(afterAttempts: attempts, rebound: rebound, swapPending: swapPending) == expected)
}

@Test
func samplesThePanelOnlyOnceTheQuickPhaseIsOver() {
    #expect(!PanelSwapCadence.isPatient(afterAttempts: PanelSwapCadence.quickAttempts - 1))
    #expect(PanelSwapCadence.isPatient(afterAttempts: PanelSwapCadence.quickAttempts))
}
