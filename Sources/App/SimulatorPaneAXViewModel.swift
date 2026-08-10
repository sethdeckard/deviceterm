// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimulatorPaneAXViewModel: observable state for the AX inspector
// side panel. Holds the cursor-driven AX label (the focused element
// under the mouse pointer) that the AX-inspector mouse-move
// tracking populates.
//
// The model is intentionally minimal. The AX RPC surface drives a
// label-under-cursor flow, and the side panel presents that
// information in a dedicated 240pt-wide pane on the right
// of the sim pixels, satisfying the "no AX printout on sim pixels +
// no taller chrome" constraint.

import Foundation
import Observation

@MainActor
@Observable
final class SimulatorPaneAXViewModel {
    /// Latest AX element label under the cursor when the inspector is
    /// active. Nil while inactive or between hits. Mirrored from
    /// `PaneChromeViewModel.axInspectorLabel` so the existing
    /// daemon-driven update path stays one-source: the chrome's
    /// throttled update sets both fields in lockstep.
    var label: String?

    init(label: String? = nil) {
        self.label = label
    }
}
