// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

enum TabCloseGate: Equatable, Sendable {
    /// Show the existing sim-disposition prompt (`CloseDecisions.tabClose`
    /// / `.bulkTabClose` / `.windowClose`); its outcome picks the mode
    /// or cancels.
    case simDisposition
    /// Confirm that a configured automation program should stop. Never
    /// suppressible, unlike the multi-pane confirm: someone who once ticked
    /// "don't ask again" on a crowded tab has not agreed to kill a daemon
    /// without being told. On proceed, dispatch with `mode`.
    case programConfirm(mode: PaneCloseMode)
    /// Apply the multi-pane confirm policy; suppression may proceed
    /// without an alert. On proceed, dispatch with `mode`.
    case multiPaneConfirm(mode: PaneCloseMode)
    /// No prompt applies; dispatch with `mode`.
    case close(mode: PaneCloseMode)
}
