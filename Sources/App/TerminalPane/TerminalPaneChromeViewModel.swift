// SPDX-License-Identifier: GPL-3.0-or-later
//
// TerminalPaneChromeViewModel: observable state for the minimal
// terminal pane chrome (the thin band between the pane focus border
// and the libghostty surface). The chrome paints just a hover-revealed
// centered ⋯ handle; the tab strip already shows the tab/pane title,
// and close lives in the ⋯ menu, so the VM is just one action
// closure.

import Foundation
import Observation

@MainActor
@Observable
final class TerminalPaneChromeViewModel {
    /// Open the existing right-click menu at the ⋯ button, using the same
    /// `NSMenu` builder the pane's right-click handler uses.
    var onOpenContextMenu: () -> Void = {}
}
