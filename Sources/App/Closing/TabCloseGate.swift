// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

enum TabCloseGate: Equatable, Sendable {
    /// Show the existing sim-disposition prompt (`CloseDecisions.tabClose`
    /// / `.bulkTabClose` / `.windowClose`); its outcome picks the mode
    /// or cancels.
    case simDisposition
    /// Apply the multi-pane confirm policy; suppression may proceed
    /// without an alert. On proceed, dispatch with `mode`.
    case multiPaneConfirm(mode: PaneCloseMode)
    /// No prompt applies; dispatch with `mode`.
    case close(mode: PaneCloseMode)
}
