// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

// The gate is the one-prompt-max rule for a tab close: the
// sim-disposition prompt wins whenever it would run (its Cancel doubles
// as the multi-pane confirmation), the multi-pane confirm covers the
// closes the sim prompt skips, and a stored sim answer rides through as
// the confirm's dispatch mode.

@Test("tab-close gate arm selection", arguments: [
    // No sims at stake: mode is detach, pane count picks the confirm.
    (false, nil, false, TabCloseGate.close(mode: .detach)),
    (false, nil, true, TabCloseGate.multiPaneConfirm(mode: .detach)),
    // A pinned decision without sims at stake is ignored: there is no
    // sim question for it to answer on this close.
    (false, TabCloseDecision.shutdown, true, TabCloseGate.multiPaneConfirm(mode: .detach)),
    (false, TabCloseDecision.shutdown, false, TabCloseGate.close(mode: .detach)),
    // Sims at stake, nothing stored: the sim prompt runs and is the
    // confirmation, whatever the pane count.
    (true, nil, false, TabCloseGate.simDisposition),
    (true, nil, true, TabCloseGate.simDisposition),
    // Sims at stake, answer stored: the stored mode dispatches, gated
    // by the confirm only when the tab is multi-pane.
    (true, TabCloseDecision.detach, true, TabCloseGate.multiPaneConfirm(mode: .detach)),
    (true, TabCloseDecision.shutdown, true, TabCloseGate.multiPaneConfirm(mode: .shutdown)),
    (true, TabCloseDecision.detach, false, TabCloseGate.close(mode: .detach)),
    (true, TabCloseDecision.shutdown, false, TabCloseGate.close(mode: .shutdown)),
    // `.cancel` is unreachable from the stored tiers; totality maps it
    // to detach rather than trapping.
    (true, TabCloseDecision.cancel, true, TabCloseGate.multiPaneConfirm(mode: .detach)),
    (true, TabCloseDecision.cancel, false, TabCloseGate.close(mode: .detach))
])
func gatesTabClose(
    simsAffected: Bool,
    pinned: TabCloseDecision?,
    multiPane: Bool,
    expected: TabCloseGate
) {
    #expect(
        TabCloseGateDecision.gate(
            simsAffected: simsAffected,
            pinnedSimDecision: pinned,
            multiPane: multiPane
        ) == expected
    )
}

// A configured automation program adds a third question. It outranks the
// multi-pane confirm, which is suppressible, and yields to the sim prompt,
// whose Cancel already asks the question.

@Test("tab-close gate arm selection with a program at stake", arguments: [
    // Nothing else at stake: the program confirm replaces a plain close.
    (false, nil, false, TabCloseGate.programConfirm(mode: .detach)),
    // It outranks the multi-pane confirm, because that one can be
    // suppressed and stopping a configured program must not be.
    (false, nil, true, TabCloseGate.programConfirm(mode: .detach)),
    // The sim prompt still wins: one gesture, one sheet.
    (true, nil, false, TabCloseGate.simDisposition),
    (true, nil, true, TabCloseGate.simDisposition),
    // A stored sim answer rides through as the program confirm's mode,
    // exactly as it does for the multi-pane confirm.
    (true, TabCloseDecision.shutdown, false, TabCloseGate.programConfirm(mode: .shutdown)),
    (true, TabCloseDecision.detach, true, TabCloseGate.programConfirm(mode: .detach))
])
func gatesTabCloseWithAProgram(
    simsAffected: Bool,
    pinned: TabCloseDecision?,
    multiPane: Bool,
    expected: TabCloseGate
) {
    #expect(
        TabCloseGateDecision.gate(
            simsAffected: simsAffected,
            pinnedSimDecision: pinned,
            multiPane: multiPane,
            programsAffected: true
        ) == expected
    )
}

/// Omitting `programsAffected` selects by the Simulator and multi-pane
/// rules alone.
@Test("no program at stake leaves the gate unchanged")
func gateIsUnchangedWithoutAProgram() {
    #expect(
        TabCloseGateDecision.gate(simsAffected: false, pinnedSimDecision: nil, multiPane: true)
            == .multiPaneConfirm(mode: .detach)
    )
}
