// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// The value record of one placeholder pane shown
/// while a sim/device attach is in flight, or after it failed and is
/// awaiting Retry. A GUI-only concept the daemon never sees: the Router
/// inserts a pending pane immediately (so the layout changes the instant
/// the user acts), runs the attach off the serial route drain, then
/// swaps this placeholder for the real `SimPaneState`/`DevicePaneState`
/// once `device.attach` / `physicalDevice.attach` returns, or flips
/// `phase` to `.failed` so the pane surfaces the error + a Retry button.
///
/// Keyed by `PendingPaneID` (not the target identity) because the real
/// daemon pane id isn't known until attach completes; `target` records
/// which sim/device this placeholder is attaching and is the dedup key
/// against the tab's mounted (`simPanes`/`devicePanes`) and other
/// pending panes.
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
    /// The typed-array position to take when the pane mounts, recorded from
    /// where it came from so a pane being re-attached lands back in its own
    /// slot. Set only by the in-place re-attach paths (helper recovery and
    /// the post-reboot resurrect), which read it off `simRecoveryOrder`; a
    /// pane arriving in the tab for the first time has no position to
    /// restore and passes nil, which appends.
    ///
    /// Mutable because recovery renumbers a tab's placeholders together: a
    /// placeholder that outlived an earlier recovery still carries the index
    /// it was minted with, which no longer lines up with the ones being
    /// handed to the panes recovering alongside it.
    var atIndex: Int?
    /// Whether `displayName` is a label only, and the attach resolves the
    /// name for itself.
    ///
    /// False on every ordinary attach, where the caller's requested label is
    /// also the name to attach with, and one field serves both. True for a
    /// pane being re-attached after a helper restart: the label it is already
    /// showing is the resolved, composed "Name · Type" form, which the
    /// placeholder keeps so the slot doesn't rename itself to a UDID stub
    /// mid-recovery, but handing that back as the bare name would compose the
    /// type onto it a second time. Retry reads this for the same reason the
    /// first attach does.
    let resolvesName: Bool
    /// Attach lifecycle: in-flight, or failed-with-message (Retry shown).
    var phase: PendingPanePhase

    /// The name to hand an attach, which is the requested label unless the
    /// attach is resolving it (see `resolvesName`).
    var attachName: String? { resolvesName ? nil : displayName }

    init(
        id: PendingPaneID,
        target: PaneTarget,
        displayName: String?,
        family: String? = nil,
        atIndex: Int? = nil,
        resolvesName: Bool = false,
        phase: PendingPanePhase = .attaching
    ) {
        self.id = id
        self.target = target
        self.displayName = displayName
        self.family = family
        self.atIndex = atIndex
        self.resolvesName = resolvesName
        self.phase = phase
    }
}
