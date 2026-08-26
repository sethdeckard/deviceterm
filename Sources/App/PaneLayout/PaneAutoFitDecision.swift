// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Which sim panes need their size preset re-applied after a tree change.
///
/// `PaneLayoutViewController` re-fits a sim when it is new or its parent
/// path changes. It preserves manual sizing when a re-attach or a sibling
/// reorder leaves the parent path unchanged, which matters because the fit
/// moves a divider and the resulting `splitViewDidResizeSubviews` stores
/// that over the user's proportions.
///
/// State is keyed by `PaneTarget` rather than by slot, because a pane does
/// not hold one slot for its whole life. Attaching, and re-attaching after a
/// reboot or a helper restart, both put a `.pending` placeholder in the tree
/// and swap the real leaf in when the attach lands. Keyed by target, that is
/// one pane throughout.
enum PaneAutoFitDecision {
    /// The result of folding one tree into the running path state.
    struct Outcome: Equatable {
        /// Replaces the caller's stored paths.
        let paths: [PaneTarget: [Int]]
        /// Sim slots to arm for a fit on the next layout pass.
        let needsFit: Set<PaneSlot>
    }

    /// Fold `tree` into `previous`, returning the new path state and the sims
    /// that need fitting.
    ///
    /// A sim needs a fit when it is new to the tab or its **parent path**
    /// changed. A sibling shuffle (an existing sim's index moving [1]→[2]
    /// because a new sim was inserted before it) leaves the parent path alone
    /// and does not re-fit, which keeps one new attach from cascading divider
    /// moves through every sim under the same root split until one collapses
    /// to its minimum thickness. Only the path is compared, so flipping a
    /// split's axis in place leaves its panes unfitted.
    ///
    /// **Only a mounted sim records a current tree path.** A placeholder
    /// carries forward its target's last mounted path, so the comparison on
    /// return is against where the user last saw the pane, not against
    /// wherever its placeholder drifted to in between. A placeholder does
    /// move: a sibling closing compacts its parent, which changes the
    /// placeholder's path without changing the pane's history. Carrying the
    /// mounted path forward is what still gets such a pane its fit, because
    /// its parent really did change.
    ///
    /// A pane attaching for the first time has no carried-forward path, so
    /// it is new when it mounts and takes its initial fit. That is the
    /// ordinary attach, and it reaches here through the same placeholder
    /// swap a re-attach does; the carried path is the only thing that tells
    /// them apart.
    ///
    /// A target with neither a mounted leaf nor a placeholder has left the
    /// tab, and its entry goes with it. Attaching it again later starts over
    /// as new. A placeholder left `.failed` and awaiting Retry still counts:
    /// a re-attach carries its previous path through Retry, while a first
    /// attach stays new and takes its initial fit once Retry succeeds.
    static func advance(
        previous: [PaneTarget: [Int]],
        tree: PaneNode,
        pendingTargets: [PendingPaneID: PaneTarget]
    ) -> Outcome {
        var mounted: [String: [Int]] = [:]
        var inFlight: Set<PaneTarget> = []
        walkLeaves(node: tree, path: []) { slot, path in
            switch slot {
            case let .sim(udid):
                mounted[udid] = path

            case let .pending(id):
                if let target = pendingTargets[id] { inFlight.insert(target) }

            case .terminal, .device:
                break
            }
        }
        var paths: [PaneTarget: [Int]] = [:]
        var needsFit: Set<PaneSlot> = []
        for (udid, path) in mounted {
            paths[.sim(udid: udid)] = path
            guard let oldPath = previous[.sim(udid: udid)] else {
                needsFit.insert(.sim(udid: udid))
                continue
            }
            if path.dropLast() != oldPath.dropLast() {
                needsFit.insert(.sim(udid: udid))
            }
        }
        for target in inFlight {
            // Carried forward unchanged, never rewritten from the
            // placeholder's own path. Absent from `previous` means this is a
            // first attach, and it stays absent so the pane reads as new when
            // it mounts.
            if let carried = previous[target] {
                paths[target] = carried
            }
        }
        return Outcome(paths: paths, needsFit: needsFit)
    }

    private static func walkLeaves(
        node: PaneNode,
        path: [Int],
        body: (PaneSlot, [Int]) -> Void
    ) {
        switch node {
        case let .leaf(slot):
            body(slot, path)

        case let .split(_, children, _):
            for (index, child) in children.enumerated() {
                walkLeaves(node: child, path: path + [index], body: body)
            }
        }
    }
}
