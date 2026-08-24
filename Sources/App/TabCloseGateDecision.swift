// SPDX-License-Identifier: GPL-3.0-or-later
//
// TabCloseGateDecision: which question (if any) a tab or window close
// asks, and the close mode it dispatches with.
//
// Two prompts guard these closes, and one gesture must never stack
// them. The sim-disposition prompt (Detach / Shut Down / Cancel) runs
// whenever booted owned sims are at stake and no stored answer covers
// them; its Cancel button already confirms the close, so it doubles as
// the multi-pane confirmation. The plain multi-pane confirm
// (Close / Cancel) runs only when the sim prompt won't: no sims at
// stake, or the sim answer is stored. In the stored case the confirm
// dispatches with that stored mode, so "don't ask about sims" keeps
// meaning what the user picked.
//
// Pure so the arm selection is unit-testable; the multi-pane confirm's
// own suppression lookup stays in `CloseDecisions`, mirroring how
// `askBootedSimDisposition` short-circuits internally.

import DaemonProtocol

enum TabCloseGateDecision {
    /// `pinnedSimDecision` is the `CloseSuppressionState.lookupClose`
    /// result and is only meaningful when `simsAffected`; callers pass
    /// nil otherwise and the function ignores it regardless.
    static func gate(
        simsAffected: Bool,
        pinnedSimDecision: TabCloseDecision?,
        multiPane: Bool
    ) -> TabCloseGate {
        if simsAffected, pinnedSimDecision == nil {
            return .simDisposition
        }
        // The stored tiers never hold `.cancel` (recording is skipped on
        // Cancel), so mapping it to `.detach` here is totality, not a
        // reachable behavior.
        let mode: PaneCloseMode =
            simsAffected && pinnedSimDecision == .shutdown ? .shutdown : .detach
        return multiPane ? .multiPaneConfirm(mode: mode) : .close(mode: mode)
    }
}
