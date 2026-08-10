// SPDX-License-Identifier: GPL-3.0-or-later
//
// PendingPaneState: the value record of one placeholder pane shown
// while a sim/device attach is in flight, or after it failed and is
// awaiting Retry. A GUI-only concept the daemon never sees: the Router
// inserts a pending pane immediately (so the layout changes the instant
// the user acts), runs the attach off the serial route drain, then
// swaps this placeholder for the real `SimPaneState`/`DevicePaneState`
// once `device.attach` / `physicalDevice.attach` returns, or flips
// `phase` to `.failed` so the pane surfaces the error + a Retry button.
//
// Keyed by `PendingPaneID` (not the target identity) because the real
// daemon pane id isn't known until attach completes; `target` records
// which sim/device this placeholder is attaching and is the dedup key
// against the tab's mounted (`simPanes`/`devicePanes`) and other
// pending panes.

import DaemonProtocol

struct PendingPaneState: Identifiable, Equatable, Sendable {
    let id: PendingPaneID
    /// Which sim/device this placeholder is attaching: the target-based
    /// dedup key shared with mounted + other pending panes.
    let target: PaneTarget
    /// The caller's requested label, or nil to resolve the name during
    /// attach (the CLI-claim path passes nil). Kept optional rather than a
    /// pre-derived string, so a Retry re-runs the attach with the same
    /// name-resolution semantics. The view derives a shown label from
    /// this (falling back to a `target`-prefix placeholder).
    let displayName: String?
    /// Coarse device family (wire string), used to size the placeholder
    /// leaf with the same metrics the real pane will take so the success
    /// swap doesn't resize. nil → `.unknown` → phone-default.
    let family: String?
    /// Original typed-array index to restore on the post-attach insert
    /// (resurrect fidelity; mirrors `Route.attachSimPane`'s `atIndex`).
    /// nil appends.
    let atIndex: Int?
    /// Attach lifecycle: in-flight, or failed-with-message (Retry shown).
    var phase: PendingPanePhase

    init(
        id: PendingPaneID,
        target: PaneTarget,
        displayName: String?,
        family: String? = nil,
        atIndex: Int? = nil,
        phase: PendingPanePhase = .attaching
    ) {
        self.id = id
        self.target = target
        self.displayName = displayName
        self.family = family
        self.atIndex = atIndex
        self.phase = phase
    }
}
