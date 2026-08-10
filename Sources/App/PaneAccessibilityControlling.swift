// SPDX-License-Identifier: GPL-3.0-or-later
//
// Role protocol: accessibility-tree queries on a sim pane.
//
// Carved out so consumers that need just AX (the chrome's AX
// inspector overlay) don't depend on the broader `PaneControlling`
// surface. Matches the per-role split per AGENTS.md ("narrow
// consumers must take the smallest role they need").
//
// Returns a short one-line summary (role / label / identifier) rather
// than the raw JSON the wire emits. The chrome's AX inspector wants
// "what's under the cursor right now"; full tree introspection is
// the CLI's `ax tree` surface. Implementations decode the response
// JSON and join interesting fields; the chrome just prints the
// string.

import Foundation

@MainActor
protocol PaneAccessibilityControlling: AnyObject {
    /// `pane.ax.point`: query the AX element at normalized (x, y) on
    /// the device's display. Returns a short summary string suitable
    /// for inline display (`role · label`, or just `label`, or just
    /// `role` if neither is present). Returns nil when the daemon
    /// reports no element at that point (e.g. cursor over chrome,
    /// off-screen, between elements).
    func paneAxPoint(paneId: String, x: Double, y: Double) async throws -> String?
}
