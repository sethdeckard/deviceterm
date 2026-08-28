// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Observation

/// One window's open tabs + selection. An
/// `@Observable` nav state the TabStripViewController reconciles its
/// strip to. Mutated by the Router; the close-index-follow selection
/// math is a pure static so it can be unit-tested directly. The one
/// exception is cross-window tab drag: the AppDelegate tab-transfer
/// coordinator calls `detach` / `insert` directly to relocate a tab's
/// `TabState` between two windows' instances (the Router can't, having
/// no AppKit access to move the tab's live view controller).
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
    /// in-flight/failed (pending pane) in `tab`. The Router's optimistic
    /// attach and orphan-reattach paths check this so menu, CLI, discovery,
    /// and orphan adoption can't stack a second (or a duplicate *failed*)
    /// pane for a target already present. Sim UDIDs compare
    /// case-insensitively, the same normalization `replacePendingWithSim`
    /// uses, because UDID casing varies across the attach paths.
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
        // Clear the spawning-terminal hint if it pointed at the terminal we
        // just dropped, so the Router's optimistic attach path doesn't carry
        // a dead id into `addPendingPane`. That method falls back to the
        // tab's primary when the anchor is no longer a live leaf, so this is
        // the outer of two guards against a placeholder landing in
        // `pendingPanes` but nowhere in the layout tree.
        if tabs[index].lastFocusedTerminal == terminalID {
            tabs[index].lastFocusedTerminal = nil
        }
    }

    /// Record that `terminalID` was the last terminal in `tabID` to
    /// receive keyboard focus. Wired up from each terminal pane
    /// wrapper's responder-chain hook so the value follows what the
    /// user is actually typing in. Read by `Router.attachPaneOptimistically`
    /// as the spawning-terminal heuristic: a `xcrun simctl boot Foo` typed
    /// in pane B places the booted sim next to B even though the
    /// daemon's attach event doesn't carry per-terminal attribution
    /// yet. Falls back to `primaryTerminal` until focus is recorded, and
    /// again if the recorded terminal is removed.
    func updateLastFocusedTerminal(_ terminalID: TerminalPaneID, inTab tabID: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        guard tabs[index].terminals.contains(where: { $0.id == terminalID }) else { return }
        tabs[index].lastFocusedTerminal = terminalID
    }

    /// Set a tab's presentation protection state. The Router drives the
    /// transition machine (fail-closed hide, commit on ack, revert on a
    /// definite rejection, generation ordering) and calls this to move
    /// the tab between `TabProtectionState` values; the strip and resolver
    /// read the derived `isProtected` / `isEffectivelyProtected`.
    func setProtectionState(_ state: TabProtectionState, id tabID: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[index].protectionState = state
    }

    func removeSimPane(udid: String, fromTab id: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let claim = restorePosition(ofSim: udid, in: tabs[index]) {
            releaseRestorePosition(claim, in: &tabs[index])
        }
        tabs[index].simPanes.removeAll { $0.udid == udid }
        tabs[index].paneTree = PaneTreeOps.remove(
            slot: .sim(udid: udid),
            from: tabs[index].paneTree
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

    /// Record the size preset a pane's chrome just applied. Nav state holds
    /// it because the pane's view controller does not survive the daemon
    /// record behind it being replaced, and the replace paths ferry this
    /// across the round trip. No-op if the pane is gone.
    func setSizePreset(_ preset: SimSizePreset, forPane target: PaneTarget, inTab id: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        switch target {
        case let .sim(udid):
            guard let paneIndex = tabs[index].simPanes.firstIndex(where: { $0.udid == udid })
            else { return }
            tabs[index].simPanes[paneIndex].sizePreset = preset

        case let .device(deviceId):
            guard let paneIndex = tabs[index].devicePanes
                .firstIndex(where: { $0.deviceId == deviceId })
            else { return }
            tabs[index].devicePanes[paneIndex].sizePreset = preset
        }
    }

    // MARK: - Pending panes (in-flight / failed attaches)

    /// Insert a placeholder pane and its `.pending(id)` leaf. The leaf goes
    /// after the spawning terminal, falling back to the tab's primary
    /// (always a live leaf), so the real pane swapped in later lands where
    /// the user would expect. The caller (Router) has already done the
    /// target-based dedup via `isTargetPresent`.
    ///
    /// Only a pane arriving for the first time inserts a leaf. One that is
    /// already mounted and being re-attached takes
    /// `replaceSimPaneWithPending` or `replaceDevicePaneWithPending`
    /// instead, keeping its slot.
    func addPendingPane(
        _ pending: PendingPaneState,
        toTab id: TabID,
        spawningTerminal: TerminalPaneID? = nil
    ) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].pendingPanes.append(pending)
        let leaves = PaneTreeOps.leavesInOrder(tabs[index].paneTree)
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

    /// Renumber where a placeholder will land in the typed array when it
    /// mounts. Recovery calls this as it re-enumerates a tab, because a
    /// placeholder left over from an earlier recovery carries the index it was
    /// minted with and the array has compacted since. No-op if it's gone.
    func setPendingIndex(_ atIndex: Int?, id pendingId: PendingPaneID, inTab id: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
            let paneIndex = tabs[index].pendingPanes.firstIndex(where: { $0.id == pendingId })
        else { return }
        tabs[index].pendingPanes[paneIndex].atIndex = atIndex
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
    /// array (honoring the pending's `atIndex` and `sizePreset` for
    /// resurrect fidelity, since the attach response carries neither),
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
        var restored = pane
        restored.sizePreset = pane.sizePreset ?? pending.sizePreset
        if let atIndex = pending.atIndex {
            tabs[index].simPanes.insert(
                restored,
                at: restoredIndex(atIndex, amongPendingIn: tabs[index])
            )
        } else {
            tabs[index].simPanes.append(restored)
        }
        tabs[index].paneTree = PaneTreeOps.replace(
            slot: .pending(pendingId),
            with: .sim(udid: pane.udid),
            in: tabs[index].paneTree
        )
    }

    /// Where a pane recorded at original index `atIndex` belongs in the typed
    /// array right now, given which of its siblings are still attaching.
    ///
    /// Clamping the recorded index to the array's length is only right when
    /// one pane is coming back. Several at once arrive in whatever order their
    /// attaches finish, and clamping then places an early-arriving later pane
    /// too far left, which a later arrival can't correct: three panes restored
    /// in reverse land as A, C, B. Counting instead makes the position
    /// independent of arrival order, because every sibling originally ahead of
    /// this one is either already in the array or still pending, and the
    /// pending ones are exactly the slots not yet filled.
    ///
    /// With no other pending pane ahead of it, this is the recorded index,
    /// clamped by `min`, which is the single-pane resurrect case.
    private func restoredIndex(_ atIndex: Int, amongPendingIn tab: TabState) -> Int {
        let stillComing = tab.pendingPanes.filter { ($0.atIndex ?? Int.max) < atIndex }.count
        return max(0, min(atIndex - stillComing, tab.simPanes.count))
    }

    /// Physical-device counterpart to `replacePendingWithSim`.
    func replacePendingWithDevice(id pendingId: PendingPaneID, pane: DevicePaneState, inTab id: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
            let pending = tabs[index].pendingPanes.first(where: { $0.id == pendingId })
        else { return }
        tabs[index].pendingPanes.removeAll { $0.id == pendingId }
        if tabs[index].devicePanes.contains(where: { $0.deviceId == pane.deviceId }) {
            tabs[index].paneTree = PaneTreeOps.remove(
                slot: .pending(pendingId),
                from: tabs[index].paneTree
            )
            return
        }
        var restored = pane
        restored.sizePreset = pane.sizePreset ?? pending.sizePreset
        tabs[index].devicePanes.append(restored)
        tabs[index].paneTree = PaneTreeOps.replace(
            slot: .pending(pendingId),
            with: .device(deviceId: pane.deviceId),
            in: tabs[index].paneTree
        )
    }

    /// Swap a mounted sim pane for an attaching placeholder in the slot it
    /// already occupies: the inverse of `replacePendingWithSim`, for a pane
    /// whose daemon side is gone and has to be attached again.
    ///
    /// The `.sim(udid)` leaf becomes `.pending(id)` at the same tree position
    /// via `PaneTreeOps.replace`, and the swap back lands there too, so the
    /// pane keeps its place in the layout and its divider proportions (which
    /// are keyed by tree position, not by slot) across the round trip. The
    /// size preset rides on the placeholder instead, because nothing about
    /// the pane's position records which sizing the user picked. Passing
    /// the pane's own stored `udid` matters: casing varies across the attach
    /// paths, and the leaf key carries whichever spelling the pane was mounted
    /// with. No-op if the pane is gone.
    func replaceSimPaneWithPending(
        udid: String,
        pending: PendingPaneState,
        inTab id: TabID
    ) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
            let departing = tabs[index].simPanes.first(where: { $0.udid == udid })
        else { return }
        var carried = pending
        carried.sizePreset = pending.sizePreset ?? departing.sizePreset
        tabs[index].simPanes.removeAll { $0.udid == udid }
        tabs[index].pendingPanes.append(carried)
        tabs[index].paneTree = PaneTreeOps.replace(
            slot: .sim(udid: udid),
            with: .pending(pending.id),
            in: tabs[index].paneTree
        )
    }

    /// The position a mounted sim holds in the numbering recovery hands out,
    /// or nil if it isn't in the tab.
    ///
    /// That numbering spans every sim the tab will hold once recovery settles,
    /// so it is not the array's index: a placeholder still coming back holds a
    /// position the array no longer has an entry for. `restoredIndex` maps a
    /// position to an array index by discounting the placeholders ahead of it;
    /// this walks the same sequence the other way, stepping over each position
    /// a placeholder has claimed and handing the rest to the mounted panes in
    /// array order.
    private func restorePosition(ofSim udid: String, in tab: TabState) -> Int? {
        let claimed = Set(tab.pendingPanes.compactMap { pending -> Int? in
            guard case .sim = pending.target else { return nil }
            return pending.atIndex
        })
        var position = 0
        for pane in tab.simPanes {
            while claimed.contains(position) { position += 1 }
            if pane.udid == udid { return position }
            position += 1
        }
        return nil
    }

    /// Close the gap a departing pane leaves in that numbering, so the
    /// placeholders behind it don't keep positions that no longer exist.
    ///
    /// Without this a placeholder outlives the pane it was numbered against: a
    /// pane closed while another is still coming back leaves the survivor
    /// claiming a position past the end, and the next recovery rebuilds the
    /// array around a claim that was never vacated. Only placeholders are
    /// renumbered, because a mounted pane's position is implied by where it
    /// sits in the array rather than stored.
    private func releaseRestorePosition(_ position: Int, in tab: inout TabState) {
        for index in tab.pendingPanes.indices {
            guard case .sim = tab.pendingPanes[index].target,
                let claim = tab.pendingPanes[index].atIndex,
                claim > position else { continue }
            tab.pendingPanes[index].atIndex = claim - 1
        }
    }

    /// Physical-device counterpart to `replaceSimPaneWithPending`.
    func replaceDevicePaneWithPending(
        deviceId: String,
        pending: PendingPaneState,
        inTab id: TabID
    ) {
        guard let index = tabs.firstIndex(where: { $0.id == id }),
            let departing = tabs[index].devicePanes.first(where: { $0.deviceId == deviceId })
        else { return }
        var carried = pending
        carried.sizePreset = pending.sizePreset ?? departing.sizePreset
        tabs[index].devicePanes.removeAll { $0.deviceId == deviceId }
        tabs[index].pendingPanes.append(carried)
        tabs[index].paneTree = PaneTreeOps.replace(
            slot: .device(deviceId: deviceId),
            with: .pending(pending.id),
            in: tabs[index].paneTree
        )
    }

    /// Drop a pending pane and its leaf (user hit Cancel/Close on the
    /// placeholder, or the tab is tearing down). No-op if gone.
    func removePendingPane(id pendingId: PendingPaneID, fromTab id: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let claim = tabs[index].pendingPanes.first { $0.id == pendingId }?.atIndex
        tabs[index].pendingPanes.removeAll { $0.id == pendingId }
        if let claim { releaseRestorePosition(claim, in: &tabs[index]) }
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
