// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneRatioStore: the split-view ratio state owned by
// `PaneLayoutViewController`, extracted so the state and its one subtle
// invariant (the programmatic-apply re-entrancy guard) live in a single
// cohesive unit instead of as loose properties on the view controller.
//
// The controller keeps the AppKit view-tree walking (it's bound to the
// live pane VCs via `metric`), but routes every read/write of the ratio
// dictionaries and the apply guard through this store. The pure divider
// arithmetic lives in `PaneRatioMath`.

import AppKit

@MainActor
final class PaneRatioStore {
    /// Auto-rebalance ratios per split, keyed by the split's address in
    /// the tree (its path of child indices). Lets the layout settle to
    /// proportional widths on resize.
    private var ratiosByPath: [[Int]: [CGFloat]] = [:]

    /// Tree path keyed by NSSplitView identity, populated during the
    /// controller's `rebuildHierarchy` so the resize callback and the
    /// size-preset capture can map a split back to its `ratiosByPath`
    /// entry.
    private var pathBySplitView: [ObjectIdentifier: [Int]] = [:]

    /// Re-entry-safe depth counter for the "programmatic apply in
    /// progress" gate. NSSplitView fires `splitViewDidResizeSubviews`
    /// synchronously from every `setPosition(_:ofDividerAt:)` we call,
    /// and during the rebuild window (between `rebuildHierarchy` and the
    /// next `viewDidLayout`) the subview frames are still zero, so the
    /// capture path would store [1, 0]-shaped garbage and the next
    /// layout pass would snap the divider to the far edge, collapsing
    /// the new pane to its minimum thickness. A plain Bool with
    /// `defer { = false }` would clear the guard at an inner call's
    /// defer if the apply path re-entered; the counter treats "any
    /// in-flight apply" as suppress-capture.
    private var applyDepth = 0

    /// True while a programmatic `applyRatios` pass is in flight;
    /// callers of the capture path skip it to avoid overwriting the
    /// freshly-computed ratios with transient zero-bounds frames.
    var isApplying: Bool { applyDepth > 0 }

    // MARK: - Ratios

    func ratios(forPath path: [Int]) -> [CGFloat]? {
        ratiosByPath[path]
    }

    func setRatios(_ ratios: [CGFloat], forPath path: [Int]) {
        ratiosByPath[path] = ratios
    }

    /// Drop all stored ratios (the Reset-Pane-Layout / from-scratch path).
    func clearRatios() {
        ratiosByPath.removeAll()
    }

    // MARK: - Split ↔ path registry

    func register(_ split: NSSplitView, path: [Int]) {
        pathBySplitView[ObjectIdentifier(split)] = path
    }

    func clearSplits() {
        pathBySplitView.removeAll()
    }

    func path(for split: NSSplitView) -> [Int]? {
        pathBySplitView[ObjectIdentifier(split)]
    }

    /// The identity of the split registered at `path`, if any. The
    /// controller resolves it back to the live view.
    func splitIdentifier(forPath path: [Int]) -> ObjectIdentifier? {
        for (oid, candidatePath) in pathBySplitView where candidatePath == path {
            return oid
        }
        return nil
    }

    // MARK: - Programmatic-apply guard

    /// Run `body` with the apply guard raised, restoring the previous
    /// depth afterward (re-entry safe).
    func withApply(_ body: () -> Void) {
        applyDepth += 1
        defer { applyDepth -= 1 }
        body()
    }
}
