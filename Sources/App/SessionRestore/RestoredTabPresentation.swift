// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol

/// What a restored tab's controllers apply once, when they are built, and the
/// navigation model has no other home for: the user's tab name, which the tab's
/// title model owns, and the divider proportions and fit paths its layout
/// controller owns.
///
/// Carried on `TabState.restoredPresentation` from the Router to the tab's
/// `TabContentViewController`, which consumes it at init and clears it, the
/// way `TerminalPaneState.cwd` is read once at attach.
struct RestoredTabPresentation: Equatable, Sendable {
    /// The name the user gave the tab, nil for the automatic title.
    var manualTitle: String?
    /// Divider proportions by split path.
    var ratios: [[Int]: [CGFloat]]
    /// Each restored sim leaf's path, keyed by target. See
    /// `WorkspaceRestoreLayout.Built.simFitPaths`.
    var simFitPaths: [PaneTarget: [Int]]
}
