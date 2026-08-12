// SPDX-License-Identifier: GPL-3.0-or-later
//
// TabListViewModel: one window's open tabs + selection. An
// `@Observable` nav state the TabStripViewController reconciles its
// strip to. Mutated by the Router; the close-index-follow selection
// math is a pure static so it can be unit-tested directly. The one
// exception is cross-window tab drag: the AppDelegate tab-transfer
// coordinator calls `detach` / `insert` directly to relocate a tab's
// `TabState` between two windows' instances (the Router can't, having
// no AppKit access to move the tab's live view controller).

import DaemonProtocol
import Observation

@MainActor
@Observable
final class TabListViewModel {
    private(set) var tabs: [TabState] = []
    /// Index of the selected tab, nil when there are none.
    private(set) var selectedIndex: Int?

    /// The currently-selected tab, or nil when the window has none.
    /// Used by app-level actions that target "the active tab" (e.g. the
    /// Mirror Physical Device… picker's attach).
    var selectedTab: TabState? {
        guard let selectedIndex, tabs.indices.contains(selectedIndex) else { return nil }
        return tabs[selectedIndex]
    }

    /// Selection after removing the tab at `index`. Removing a tab left of
    /// the selection shifts it down one; removing the selection (or a tab
    /// to its right) leaves the index on the right neighbor, clamped to
    /// the last tab. Returns nil when no tabs remain. Mirrors the original
    /// TabStripViewController.closeTab follow logic.
    static func selectionAfterClose(
        removing index: Int,
        selected: Int?,
        remainingCount: Int
    ) -> Int? {
        guard remainingCount > 0 else { return nil }
        var next = selected ?? 0
        if index < next { next -= 1 }
        return min(max(next, 0), remainingCount - 1)
    }

    /// Whether `target` is already mounted (sim or device pane) or
    /// in-flight/failed (pending pane) in `tab`. The Router's
    /// optimistic-insert path checks this so menu / CLI / discovery /
    /// resurrect can't stack a second (or a duplicate *failed*) pane for
    /// a target already present. Sim UDIDs compare case-insensitively,
    /// the same normalization `addSimPane` uses, because UDID casing
    /// varies across the attach paths.
    static func isTargetPresent(_ target: PaneTarget, in tab: TabState) -> Bool {
        switch target {
        case let .sim(udid):
            if tab.simPanes.contains(where: {
                $0.udid.caseInsensitiveCompare(udid) == .orderedSame
            }) { return true }
            return tab.pendingPanes.contains {
                if case let .sim(pendingUDID) = $0.target {
                    return pendingUDID.caseInsensitiveCompare(udid) == .orderedSame
                }
                return false
            }

        case let .device(deviceId):
            if tab.devicePanes.contains(where: { $0.deviceId == deviceId }) {
                return true
            }
            return tab.pendingPanes.contains { $0.target == .device(deviceId: deviceId) }
        }
    }

    /// Whether `target` is currently *shown* by `tab`: a mounted pane, or a
    /// placeholder still attaching. Narrower than `isTargetPresent`, which
    /// also counts a failed placeholder because it answers the dedup question
    /// ("has this tab claimed the target"). This answers the cleanup question
    /// ("is anything relying on the target's daemon pane"), and a failed
    /// placeholder isn't treated as relying on one. Its attempt is over, and
    /// if that attempt was a deadline expiry whose work is still running, the
    /// pane it eventually returns is reconciled on its own
    /// (`Router.detachUnclaimedPane`) rather than through this. Same
    /// case-insensitive UDID comparison.
    ///
    /// `ignoring` drops one placeholder from the answer, for the caller that
    /// IS that placeholder and is asking whether anyone *else* is relying on
    /// the target.
    static func isTargetShown(
        _ target: PaneTarget,
        in tab: TabState,
        ignoring pendingId: PendingPaneID? = nil
    ) -> Bool {
        let attaching = tab.pendingPanes.contains {
            $0.id != pendingId
                && $0.phase == .attaching
                && Self.targetsMatch($0.target, target)
        }
        if attaching { return true }
        switch target {
        case let .sim(udid):
            return tab.simPanes.contains {
                $0.udid.caseInsensitiveCompare(udid) == .orderedSame
            }

        case let .device(deviceId):
            return tab.devicePanes.contains { $0.deviceId == deviceId }
        }
    }

    /// Target equality with the UDID case-insensitivity the attach paths need.
    static func targetsMatch(_ lhs: PaneTarget, _ rhs: PaneTarget) -> Bool {
        switch (lhs, rhs) {
        case let (.sim(left), .sim(right)):
            return left.caseInsensitiveCompare(right) == .orderedSame

        case let (.device(left), .device(right)):
            return left == right

        default:
            return false
        }
    }

    /// Append a tab and select it, since new tabs become active.
    func append(_ tab: TabState) {
        tabs.append(tab)
        selectedIndex = tabs.count - 1
    }

    func select(id: TabID) {
        if let index = tabs.firstIndex(where: { $0.id == id }) {
            selectedIndex = index
        }
    }

    /// Remove a tab, following the selection per `selectionAfterClose`.
    func removeTab(id: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        selectedIndex = Self.selectionAfterClose(
            removing: index,
            selected: selectedIndex,
            remainingCount: tabs.count
        )
    }

    /// Same-window reorder: move the tab identified by `id` to `toIndex`
    /// in the array. Selection follows the *identity* of whatever was
    /// selected before (not a fixed slot), so dragging tab A past the
    /// selected tab B leaves B selected. `toIndex` is clamped to the
    /// valid range; a no-op when the tab isn't present.
    func move(id: TabID, toIndex: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let selectedID = selectedIndex.flatMap { tabs.indices.contains($0) ? tabs[$0].id : nil }
        let moved = tabs.remove(at: from)
        let clamped = min(max(toIndex, 0), tabs.count)
        tabs.insert(moved, at: clamped)
        if let selectedID {
            selectedIndex = tabs.firstIndex { $0.id == selectedID }
        }
    }

    /// Remove and return a tab for relocation to another window, with
    /// **no** daemon/session side effects. Unlike `removeTab` (paired
    /// with the Router's `closeTabRecords`), a detach keeps every
    /// session, sim, and ownership record alive inside the caller's
    /// live `TabContentViewController`, which travels with the tab.
    /// Selection follows the same `selectionAfterClose` math as a close.
    func detach(id: TabID) -> TabState? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = tabs.remove(at: index)
        selectedIndex = Self.selectionAfterClose(
            removing: index,
            selected: selectedIndex,
            remainingCount: tabs.count
        )
        return removed
    }

    /// Insert a relocated tab at `index`. `select == true` makes it the
    /// active tab (matches `append`'s "the moved/new tab becomes
    /// active"); `select == false` preserves the current selection by
    /// identity, shifting the stored index when the insert lands at or
    /// before it.
    func insert(_ tab: TabState, at index: Int, select: Bool = true) {
        let clamped = min(max(index, 0), tabs.count)
        tabs.insert(tab, at: clamped)
        if select {
            selectedIndex = clamped
        } else if let current = selectedIndex, clamped <= current {
            selectedIndex = current + 1
        }
    }

    func tab(id: TabID) -> TabState? { tabs.first { $0.id == id } }

    /// Add a terminal pane to a tab. The Router has already minted the
    /// session and built the TerminalPaneState; this records it on the
    /// nav state so the reconcile in TabContentViewController picks it
    /// up.
    ///
    /// Placement: an `anchor` present in the tree (the pane the user
    /// asked to split) splits **just that pane** along `axis` on
    /// `side`. An `axis` differing from the anchor's parent nests a
    /// sub-split, matching the terminal-emulator norm (`[[A / C] | B]`,
    /// not three stacked rows). With no anchor (the CLI / Intent path),
    /// the pane appends at the root along the tree's current axis,
    /// defaulting to horizontal for a single-leaf tab.
    ///
    /// The anchor is a slot, so a sim or device pane can be one: ⌘D
    /// with a device focused puts the new terminal beside it.
    func addTerminal(
        _ terminal: TerminalPaneState,
        toTab id: TabID,
        anchor: PaneSlot? = nil,
        axis: SplitAxis? = nil,
        side: AdjacentSide = .after
    ) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].terminals.append(terminal)
        let leaves = PaneTreeOps.leavesInOrder(tabs[index].paneTree)
        if let anchor, leaves.contains(anchor) {
            tabs[index].paneTree = PaneTreeOps.insert(
                leaf: .terminal(terminal.id),
                adjacent: anchor,
                axis: axis ?? .horizontal,
                side: side,
                in: tabs[index].paneTree
            )
        } else {
            let appendAxis = axis ?? rootAxis(of: tabs[index].paneTree) ?? .horizontal
            tabs[index].paneTree = PaneTreeOps.append(
                leaf: .terminal(terminal.id),
                axis: appendAxis,
                in: tabs[index].paneTree
            )
        }
    }

    /// Flip the axis of the split that directly contains `slot`: the
    /// ⌃⇧D "Toggle Split Direction" primitive. Only the focused pane's
    /// immediate parent split re-orients; the rest of the tree is
    /// untouched. A no-op on a single-pane tab (no split node to flip).
    /// The recursive layout reconciles to the new axis.
    func flipSplitAxis(containing slot: PaneSlot, inTab id: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].paneTree = PaneTreeOps.flippingParentAxis(
            of: slot,
            in: tabs[index].paneTree
        )
    }

    private func rootAxis(of node: PaneNode) -> SplitAxis? {
        if case let .split(axis, _, _) = node {
            return axis
        }
        return nil
    }

    /// Remove a terminal pane from a tab. Refuses to drop the primary
    /// (the last entry standing); at that point the caller should
    /// close the tab. The Router already closed the daemon session;
    /// this just drops the entry.
    func removeTerminal(id terminalID: TerminalPaneID, fromTab id: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard tabs[index].terminals.count > 1 else { return }
        tabs[index].terminals.removeAll { $0.id == terminalID }
        tabs[index].paneTree = PaneTreeOps.remove(
            slot: .terminal(terminalID),
            from: tabs[index].paneTree
        )
        // Clear the spawning-terminal hint if it pointed at the
        // terminal we just dropped. Otherwise `Router.attachPane`
        // would later pass a dead id to `addSimPane`, the tree
        // insert would silently no-op (target slot missing), and
        // a freshly-attached sim would be appended to `simPanes`
        // but never land in the layout tree (invisible pane).
        if tabs[index].lastFocusedTerminal == terminalID {
            tabs[index].lastFocusedTerminal = nil
        }
    }

    /// Record that `terminalID` was the last terminal in `tabID` to
    /// receive keyboard focus. Wired up from each terminal pane
    /// wrapper's responder-chain hook so the value follows what the
    /// user is actually typing in. Read by `Router.attachPane` as the
    /// spawning-terminal heuristic: a `xcrun simctl boot Foo` typed
    /// in pane B places the booted sim next to B even though the
    /// daemon's attach event doesn't carry per-terminal attribution
    /// yet. Falls back to `primaryTerminal` when no focus event has
    /// arrived yet (cold-start case).
    func updateLastFocusedTerminal(_ terminalID: TerminalPaneID, inTab tabID: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        guard tabs[index].terminals.contains(where: { $0.id == terminalID }) else { return }
        tabs[index].lastFocusedTerminal = terminalID
    }

    /// Set a tab's presentation privacy state. The Router drives the
    /// transition machine (fail-closed hide, commit on ack, revert on a
    /// definite rejection, generation ordering) and calls this to move
    /// the tab between `TabPrivacyState` values; the strip and resolver
    /// read the derived `isPrivate` / `isEffectivelyHidden`.
    func setPrivacyState(_ state: TabPrivacyState, id tabID: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].privacyState = state
    }

    /// `atIndex` restores resurrect-in-original-slot among existing sim
    /// panes; nil places the new sim adjacent to its spawning terminal
    /// in the layout tree. Idempotent by udid (case-insensitive, since
    /// `SimPaneState.udid` storage varies across the discovery /
    /// orphan-recovery / shim-intercept / `deviceterm pane attach` paths
    /// because some preserve `simctl list`'s uppercase and others
    /// store the daemon's lowercased canonical form). The dedup guard
    /// catches concurrent attach paths that both round-trip through
    /// `daemon.device.attach` for the same just-booted sim. Daemon-
    /// side dedup already returns the same `paneId` to both callers,
    /// but without this guard the model would still hold two
    /// `SimPaneState` entries for the same pane and the GUI would
    /// render two side-by-side MTKViews mirroring the same display.
    ///
    /// `spawningTerminal` identifies which terminal "owns" the new
    /// sim's placement. The attach event does not carry which terminal
    /// session booted the sim, so callers pass the tab's primary
    /// terminal id. The new sim lands
    /// immediately after `spawningTerminal` in the layout tree along
    /// the horizontal axis. The math is centralized here as a `.after`
    /// constant so flipping to "before" (insert to the left of the
    /// spawning terminal) is one line.
    ///
    /// `anchor`, when present, overrides the spawning-terminal
    /// heuristic and inserts the new sim next to the named slot. The
    /// resurrect path captures its pane's pre-detach neighbor and
    /// passes it here so a sim that the user dragged elsewhere
    /// reappears in the same visual slot after reboot.
    func addSimPane(
        _ pane: SimPaneState,
        toTab id: TabID,
        atIndex: Int? = nil,
        spawningTerminal: TerminalPaneID? = nil,
        anchor: ResurrectAnchor? = nil
    ) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs[index].simPanes.contains(
            where: {
            $0.udid.caseInsensitiveCompare(pane.udid) == .orderedSame
            }
            ) {
            return
        }
        // Typed lookup: explicit `atIndex` (resurrect) preserves the
        // original slot among sim-panes; nil appends to the typed
        // array. Either way, the layout tree picks up the placement
        // below. The tree drives visual placement, not the
        // typed-array index.
        if let atIndex {
            let clamped = max(0, min(atIndex, tabs[index].simPanes.count))
            tabs[index].simPanes.insert(pane, at: clamped)
        } else {
            tabs[index].simPanes.append(pane)
        }
        // Layout tree placement: an explicit resurrect anchor wins
        // (preserves the pre-detach visual slot), then spawning-
        // terminal (the default for discovery / orphan-recovery / shim
        // attribute), with the primary as the final fallback.
        let leaves = PaneTreeOps.leavesInOrder(tabs[index].paneTree)
        if let anchor, leaves.contains(anchor.slot) {
            tabs[index].paneTree = PaneTreeOps.insert(
                leaf: .sim(udid: pane.udid),
                adjacent: anchor.slot,
                axis: .horizontal,
                side: anchor.side,
                in: tabs[index].paneTree
            )
        } else {
            // Belt-and-braces validate the anchor is actually in the
            // tree before handing it to `PaneTreeOps.insert`. Without
            // this, a caller passing a stale `spawningTerminal` id
            // (e.g. the terminal closed between focus and attach)
            // would land at `insertWalk(…) ?? tree`, which returns
            // the unchanged tree. The typed-array append above
            // would have already happened, so the new sim would be
            // in `simPanes` but invisible in the layout. Fall back
            // to the tab's primary in that case (always a live leaf).
            let leaves = PaneTreeOps.leavesInOrder(tabs[index].paneTree)
            let candidate = spawningTerminal ?? tabs[index].primaryTerminal.id
            let anchorTerminal = leaves.contains(.terminal(candidate))
                ? candidate
                : tabs[index].primaryTerminal.id
            tabs[index].paneTree = PaneTreeOps.insert(
                leaf: .sim(udid: pane.udid),
                adjacent: .terminal(anchorTerminal),
                axis: .horizontal,
                side: .after,
                in: tabs[index].paneTree
            )
        }
    }

    func removeSimPane(udid: String, fromTab id: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].simPanes.removeAll { $0.udid == udid }
        tabs[index].paneTree = PaneTreeOps.remove(
            slot: .sim(udid: udid),
            from: tabs[index].paneTree
        )
    }

    /// Append a physically-connected device pane to a tab. The Router
    /// has already done `physicalDevice.attach` and built the
    /// `DevicePaneState`; this records it so the reconcile in
    /// `TabContentViewController` builds a pane VC for it. Parallels
    /// `addSimPane` but without the resurrect `atIndex` / `anchor`
    /// machinery, since device panes are never persisted or auto-resurrected,
    /// so there's no original-slot restoration to honor.
    ///
    /// Idempotent by `deviceId`: the picker / CLI / shim attach paths
    /// can all target the same connected device, and a duplicate attach
    /// must not stack two MirroredPaneState entries (two MTKViews
    /// mirroring the same device). The new pane lands immediately after
    /// `spawningTerminal` in the layout tree (the primary terminal as
    /// the fallback when the hint is nil or stale), matching the sim
    /// placement rule.
    func addDevicePane(
        _ pane: DevicePaneState,
        toTab id: TabID,
        spawningTerminal: TerminalPaneID? = nil
    ) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs[index].devicePanes.contains(where: { $0.deviceId == pane.deviceId }) {
            return
        }
        tabs[index].devicePanes.append(pane)
        // Anchor the new leaf next to the spawning terminal (the
        // terminal the user most recently typed in), falling back to
        // the primary when the hint is nil or no longer a live leaf.
        // Without the liveness check a stale id would make
        // `PaneTreeOps.insert` no-op and strand the pane in the typed
        // array but invisible in the tree (the same trap `addSimPane`
        // guards against).
        let leaves = PaneTreeOps.leavesInOrder(tabs[index].paneTree)
        let candidate = spawningTerminal ?? tabs[index].primaryTerminal.id
        let anchorTerminal = leaves.contains(.terminal(candidate))
            ? candidate
            : tabs[index].primaryTerminal.id
        tabs[index].paneTree = PaneTreeOps.insert(
            leaf: .device(deviceId: pane.deviceId),
            adjacent: .terminal(anchorTerminal),
            axis: .horizontal,
            side: .after,
            in: tabs[index].paneTree
        )
    }

    func removeDevicePane(deviceId: String, fromTab id: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].devicePanes.removeAll { $0.deviceId == deviceId }
        tabs[index].paneTree = PaneTreeOps.remove(
            slot: .device(deviceId: deviceId),
            from: tabs[index].paneTree
        )
    }

    // MARK: - Pending panes (in-flight / failed attaches)

    /// Insert a placeholder pane and its `.pending(id)` leaf. Placement
    /// mirrors `addSimPane` exactly: an explicit resurrect `anchor`
    /// wins, then the spawning terminal, then the tab's primary (always
    /// a live leaf), so the real pane swapped in later lands where the
    /// user would expect. The caller (Router) has already done the
    /// target-based dedup via `isTargetPresent`.
    func addPendingPane(
        _ pending: PendingPaneState,
        toTab id: TabID,
        spawningTerminal: TerminalPaneID? = nil,
        anchor: ResurrectAnchor? = nil
    ) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].pendingPanes.append(pending)
        let leaves = PaneTreeOps.leavesInOrder(tabs[index].paneTree)
        if let anchor, leaves.contains(anchor.slot) {
            tabs[index].paneTree = PaneTreeOps.insert(
                leaf: .pending(pending.id),
                adjacent: anchor.slot,
                axis: .horizontal,
                side: anchor.side,
                in: tabs[index].paneTree
            )
        } else {
            let candidate = spawningTerminal ?? tabs[index].primaryTerminal.id
            let anchorTerminal = leaves.contains(.terminal(candidate))
                ? candidate
                : tabs[index].primaryTerminal.id
            tabs[index].paneTree = PaneTreeOps.insert(
                leaf: .pending(pending.id),
                adjacent: .terminal(anchorTerminal),
                axis: .horizontal,
                side: .after,
                in: tabs[index].paneTree
            )
        }
    }

    /// Flip a pending pane to `.failed(message)` (attach threw). The
    /// `.pending` leaf stays in the tree so the pane keeps its slot and
    /// surfaces the error + Retry. No-op if the pending pane is gone.
    func failPendingPane(id pendingId: PendingPaneID, message: String, inTab id: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
            let paneIndex = tabs[index].pendingPanes.firstIndex(where: { $0.id == pendingId })
        else { return }
        tabs[index].pendingPanes[paneIndex].phase = PendingPaneReducer.reduce(
            tabs[index].pendingPanes[paneIndex].phase,
            .attachFailed(message)
        )
    }

    /// Flip a failed pending pane back to `.attaching` (user hit Retry).
    /// The Router spawns a fresh attach Task after this. No-op if gone.
    func retryPendingPane(id pendingId: PendingPaneID, inTab id: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
            let paneIndex = tabs[index].pendingPanes.firstIndex(where: { $0.id == pendingId })
        else { return }
        tabs[index].pendingPanes[paneIndex].phase = PendingPaneReducer.reduce(
            tabs[index].pendingPanes[paneIndex].phase,
            .retried
        )
    }

    /// Swap a successful pending pane for the real sim pane in place:
    /// drop the pending record, insert the `SimPaneState` into the typed
    /// array (honoring the pending's `atIndex` for resurrect fidelity),
    /// and rewrite the `.pending(id)` leaf to `.sim(udid)` at the exact
    /// same tree position via `PaneTreeOps.replace` (preserving divider
    /// proportions). No-op if the pending pane is gone; if the target is
    /// somehow already mounted, just drop the placeholder.
    func replacePendingWithSim(id pendingId: PendingPaneID, pane: SimPaneState, inTab id: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
            let pending = tabs[index].pendingPanes.first(where: { $0.id == pendingId })
        else { return }
        tabs[index].pendingPanes.removeAll { $0.id == pendingId }
        let alreadyMounted = tabs[index].simPanes.contains {
            $0.udid.caseInsensitiveCompare(pane.udid) == .orderedSame
        }
        if alreadyMounted {
            tabs[index].paneTree = PaneTreeOps.remove(
                slot: .pending(pendingId),
                from: tabs[index].paneTree
            )
            return
        }
        if let atIndex = pending.atIndex {
            let clamped = max(0, min(atIndex, tabs[index].simPanes.count))
            tabs[index].simPanes.insert(pane, at: clamped)
        } else {
            tabs[index].simPanes.append(pane)
        }
        tabs[index].paneTree = PaneTreeOps.replace(
            slot: .pending(pendingId),
            with: .sim(udid: pane.udid),
            in: tabs[index].paneTree
        )
    }

    /// Sim sibling of `replacePendingWithSim` for a physical-device pane.
    func replacePendingWithDevice(id pendingId: PendingPaneID, pane: DevicePaneState, inTab id: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
            tabs[index].pendingPanes.contains(where: { $0.id == pendingId })
        else { return }
        tabs[index].pendingPanes.removeAll { $0.id == pendingId }
        if tabs[index].devicePanes.contains(where: { $0.deviceId == pane.deviceId }) {
            tabs[index].paneTree = PaneTreeOps.remove(
                slot: .pending(pendingId),
                from: tabs[index].paneTree
            )
            return
        }
        tabs[index].devicePanes.append(pane)
        tabs[index].paneTree = PaneTreeOps.replace(
            slot: .pending(pendingId),
            with: .device(deviceId: pane.deviceId),
            in: tabs[index].paneTree
        )
    }

    /// Drop a pending pane and its leaf (user hit Cancel/Close on the
    /// placeholder, or the tab is tearing down). No-op if gone.
    func removePendingPane(id pendingId: PendingPaneID, fromTab id: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].pendingPanes.removeAll { $0.id == pendingId }
        tabs[index].paneTree = PaneTreeOps.remove(
            slot: .pending(pendingId),
            from: tabs[index].paneTree
        )
    }

    /// Drag-to-rearrange entry point. The drag destination passes the
    /// source leaf, the target leaf the cursor was over, and the
    /// drop zone (center = swap, half-zones = insert before/after on
    /// the matching axis). `PaneTreeOps.move` handles the mechanics
    /// (single-child split compaction, sibling reordering, fresh
    /// sub-split creation), so this method is just the nav-state
    /// adapter.
    func reorderPane(
        slot: PaneSlot,
        to target: PaneSlot,
        zone: DropZone,
        inTab id: TabID
    ) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].paneTree = PaneTreeOps.move(
            slot: slot,
            to: target,
            zone: zone,
            in: tabs[index].paneTree
        )
    }

    /// Keyboard swap (⌘⇧← / ⌘⇧→): exchange the focused leaf with its
    /// in-display-order neighbor. With the unified tree's natural
    /// ordering, a terminal swaps past a sim and vice versa; there is
    /// no terminal/sim block boundary.
    func swapAdjacentPane(slot: PaneSlot, direction: Int, inTab id: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].paneTree = PaneTreeOps.swapAdjacent(
            slot: slot,
            direction: direction,
            in: tabs[index].paneTree
        )
    }
}
