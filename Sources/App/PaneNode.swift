// SPDX-License-Identifier: GPL-3.0-or-later
//
// PaneNode: the recursive layout tree backing one tab's pane
// arrangement. A node is either a `.leaf` (one terminal or sim pane)
// or a `.split` (an axis-oriented container of two-or-more child
// nodes, with per-child extents along the divider axis).
//
// The tree is the single source of truth for layout structure: order,
// nesting, and divider proportions. `TabState.terminals` /
// `simPanes` remain as typed storage so callers can look up a pane's
// state by id without walking the tree; `paneTree` says where each
// leaf lives.
//
// `PaneTreeOps` exposes pure mutations (insert next to / move /
// remove / append) that preserve four invariants:
//
//   1. Each leaf id appears at most once.
//   2. Every `.split` has at least two children. Single-child splits
//      compact to their child at mutation time.
//   3. `extents.count == children.count` for every `.split`.
//   4. The leaves visited in display order are stable across no-op
//      mutations.
//
// All operations are value-returning (no mutation in place); the
// callers swap the result into the nav state when satisfied. That
// keeps the unit tests trivial: `expect(after == expected)` is the
// whole gate.

import CoreGraphics
import Foundation

indirect enum PaneNode: Equatable, Sendable, Codable {
    case leaf(PaneSlot)
    case split(axis: SplitAxis, children: [PaneNode], extents: [CGFloat])
}
