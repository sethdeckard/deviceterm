// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// The label one terminal pane publishes for itself.
///
/// This is `TabTitleViewModel.displayTitle` scoped to a single terminal, with
/// the two tab-level tiers removed. A tab's manual title comes from `tab
/// rename` and names the tab rather than any pane in it, and the focused-device
/// tier answers "which pane is this tab naming", a question a pane naming
/// itself never asks. What remains is the terminal's own three sources, in the
/// order the tab applies them.
///
/// A tab holding one terminal, with no tab rename and no focused device pane,
/// therefore usually publishes the same string twice. The two can still
/// diverge, and the difference is where normalization runs rather than what the
/// tiers are. This type normalizes each tier before falling through to the
/// next. The tab picks its label first and normalizes afterwards, and on
/// failure restarts from the tab name, so its session-name and directory tiers
/// drop out. An invisible OSC title is the case that separates them: it wins
/// the tab's selection and then normalizes to nothing. With no usable pane name
/// under it, that leaves the tab on its own name while the pane falls through
/// to its directory basename.
/// `paneAndTabTitlesAgreeForALoneTerminal` pins the agreement and
/// `invisibleOSCTitleSeparatesPaneAndTabTitles` pins the divergence.
///
/// `name` sits below the OSC title on purpose, and it is the one ordering a
/// reader tends to expect the other way round. `pane rename` writes
/// `TerminalPaneState.name`, which feeds the tab model's *session-name* tier,
/// not its manual-title tier; putting it first here would make a pane's label
/// disagree with its own tab's for the same terminal. A renamed pane still
/// carries the user's string in `WorkspacePane.name`, which no tier can
/// suppress, so the rename is never lost, only outranked while the program in
/// the terminal is saying something more specific.
enum PaneTitleDecision {
    /// Fallback shared with `TabTitleViewModel`, so the two agree when every
    /// tier is empty. Defined on the wire type, which also needs it to decode a
    /// terminal object that predates the field.
    static let fallback = WorkspacePane.Terminal.defaultTitle

    /// Resolve the pane's label. Never empty: every candidate is normalized,
    /// and `fallback` stands in when none survives.
    ///
    /// - Parameters:
    ///   - oscTitle: Latest OSC 0/2 title from the program in the terminal.
    ///   - name: The pane's current name, as `pane rename` last left it.
    ///   - oscWorkingDirectory: Latest OSC 7 path; only its last component is
    ///     used, matching the tab label's own basename tier.
    static func title(
        oscTitle: String?,
        name: String?,
        oscWorkingDirectory: String?
    ) -> String {
        DisplayTitleNormalizer.normalize(oscTitle)
            ?? DisplayTitleNormalizer.normalize(name)
            ?? DisplayTitleNormalizer.normalize(basename(of: oscWorkingDirectory))
            ?? fallback
    }

    /// Last path component, or nil when there is no path or it has none.
    /// Mirrors `TabTitleViewModel.updateWorkingDirectory`, which reads the
    /// basename the same way.
    private static func basename(of path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let base = (path as NSString).lastPathComponent
        return base.isEmpty ? nil : base
    }
}
