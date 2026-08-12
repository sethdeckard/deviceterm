// SPDX-License-Identifier: GPL-3.0-or-later
//
// MirroredPaneState: the backend-neutral fields shared by every pane that
// mirrors a *device*: a CoreSimulator sim (`SimPaneState`) or a physically-
// connected iPhone/iPad (`DevicePaneState`). Both render + drive through the
// same `SimulatorPaneViewController` + view model off exactly these fields
// plus `target`, so the two state types are deliberately parallel.
//
// Breadcrumb toward unification: sim and device panes are kept as
// separate typed arrays (`TabState.simPanes` / `devicePanes`) so the
// load-bearing sim drag/resurrect/reconcile path stays untouched. This
// protocol is the seam a future consolidation would build on: collapse the
// two into one target-keyed pane type and most call sites already speak this
// shape. Meanwhile it lets shared code (pane VC construction, sizing) accept
// `any MirroredPaneState` instead of forking per kind.

import DaemonProtocol

protocol MirroredPaneState {
    /// Daemon pane id from the attach response. The glue creates a pane VM
    /// for this id (the attach already happened in the Router).
    var paneId: String { get }
    /// The `attachment` from the attach response that produced this pane, so
    /// a close the GUI issues can be fenced to that admission. Nil from a
    /// daemon that predates the field, which closes unconditionally.
    var attachment: UInt64? { get }
    /// Human-facing name shown in the pane chrome.
    var displayName: String { get }
    /// Coarse device family (drives watch-aware pane sizing). A physical
    /// device reports `unknown`.
    var family: String { get }
    /// Daemon-minted Crockford base32 short id (6 chars), or nil from an
    /// older daemon that predates the identifier model.
    var shortId: String? { get }
    /// Optional human-set custom name.
    var name: String? { get }
    /// Native pixel width of the device display, or nil before a surface binds.
    var pixelWidth: Int? { get }
    /// Pairs with `pixelWidth`.
    var pixelHeight: Int? { get }
    /// Per-pane device-control capabilities; nil resolves to `.simulator`.
    var capabilities: PaneCapabilities? { get }
    /// The backend-neutral identity (`.sim(udid:)` / `.device(deviceId:)`),
    /// the key under which this pane's leaf lives in the layout tree.
    var target: PaneTarget { get }
}
