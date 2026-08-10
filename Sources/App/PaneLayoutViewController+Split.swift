// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneLayoutViewController+Split: the Split Right / Split Down fallback for
// a focused device pane.
//
// These carry `TerminalPaneViewController`'s selector names on purpose,
// not new ones. A nil-targeted menu item names a single selector, so a
// differently-named method here would form no fallback at all: AppKit
// would search the chain for the terminal's selector and never reach
// this class. With matching names the chain resolves itself. A focused
// terminal claims the selector first and splits itself; a focused device
// pane does not implement it, so the search continues here and the new
// terminal lands beside the device.
//
// The same shape `+DeviceMenu` already uses, where each forwarder is
// name-identical to the pane VC method it stands in for.

import AppKit

extension PaneLayoutViewController {
    @objc
    func splitTerminalRight(_ sender: Any?) { requestSplit(axis: .horizontal) }

    @objc
    func splitTerminalDown(_ sender: Any?) { requestSplit(axis: .vertical) }

    /// Anchor on the focused pane so the split lands where the user is
    /// looking. With focus outside the tab there is no anchor, and a nil
    /// one appends at the root along the requested axis. The CLI path
    /// also appends at the root, but passes no axis and so follows the
    /// tree's current one.
    private func requestSplit(axis: SplitAxis) {
        onSplitRequested?(focusedSlot(), axis)
    }
}
