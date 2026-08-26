// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Pure decision, should we inject an explanatory
/// `note` into the daemon's `ax tree` response, and which one?
///
/// Split out of `PaneCoordinator.accessibilityTree(paneId:)` so the
/// note-injection logic is unit-testable without a live sim. The live
/// test sees the un-annotated bridge dict; this pure helper covers
/// the daemon-side branch.
///
/// The rule is narrow: when the bridge returns an empty `children` array
/// AND the pane's device family is `watch`, inject
/// `note = AXTreeNote.watchOSEnumerationUnsupported`. An empty tree on any
/// other family, and a non-empty tree on watchOS, both pass through
/// unchanged. The note fires only on the degenerate-and-known-limited
/// intersection, not on the family alone.
enum AXTreeAnnotator {
    /// Return `tree` with an `AXTreeNote` injected at top level when
    /// the (family, tree-shape) pair indicates a known limitation;
    /// otherwise return `tree` unchanged. Top-level `note` placement
    /// puts it next to `role` / `frame` / `children` in the tree
    /// dict, so agents read `tree.note` rather than walking children
    /// to find it.
    static func annotate(
        tree: [String: Any],
        family: DeviceFamily
    ) -> [String: Any] {
        guard family == .watch,
            let children = tree["children"] as? [Any],
            children.isEmpty
        else { return tree }
        var annotated = tree
        annotated["note"] = AXTreeNote.watchOSEnumerationUnsupported.rawValue
        return annotated
    }
}
