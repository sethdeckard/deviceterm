// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneLayoutViewController+PaneNavigation: the six Select Pane
// responder-chain actions. An extension file for the same reason
// `+DeviceMenu` is one, keeping a set of menu forwarders out of the
// controller's own file.
//
// Focus moves synchronously here rather than through a Route. Which
// pane holds first responder is AppKit state the layout controller
// already owns and reconciles, not navigation state the workspace
// models, so a round trip through the router would have nothing to
// mutate. That also keeps a held-down arrow from queueing behind an
// in-flight route.
//
// Both walks read the *current* focus at the moment they run, so a
// repeated press always steps from where the previous one landed.

import AppKit

extension PaneLayoutViewController {
    @objc
    func selectNextPane(_ sender: Any?) { stepFocus(delta: +1) }

    @objc
    func selectPreviousPane(_ sender: Any?) { stepFocus(delta: -1) }

    @objc
    func selectPaneLeft(_ sender: Any?) { moveFocus(.left) }

    @objc
    func selectPaneRight(_ sender: Any?) { moveFocus(.right) }

    @objc
    func selectPaneAbove(_ sender: Any?) { moveFocus(.above) }

    @objc
    func selectPaneBelow(_ sender: Any?) { moveFocus(.below) }

    private func stepFocus(delta: Int) {
        let target = PaneFocusOrderMath.nextSlot(
            from: focusedSlot(),
            delta: delta,
            order: PaneTreeOps.leavesInOrder(tree)
        )
        restoreFocus(to: target)
    }

    private func moveFocus(_ direction: PaneFocusDirection) {
        // Directional movement needs somewhere to move *from*. With
        // focus outside the tab there is no origin, and guessing one
        // would send the user to an arbitrary pane.
        guard let origin = focusedSlot() else { return }
        restoreFocus(
            to: PaneDirectionalFocusMath.neighbor(
                of: origin,
                direction: direction,
                frames: slotFrames()
            )
        )
    }
}
