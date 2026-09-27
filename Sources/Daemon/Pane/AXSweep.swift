// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreSimulatorBridge
import DaemonProtocol
import Foundation

/// Pure math behind `pane.ax.point` and `pane.ax.sweep`: the grid the
/// sweep walks, the key that collapses it to unique elements, the
/// per-cell error classifier, and the displayed-to-native coordinate
/// conversion both verbs hand the bridge. `pane.ax.tree` uses the geometry
/// helpers too, for normalization and for its completeness probe.
///
/// Kept out of `PaneCoordinator` so grid density, dedup uniqueness, and
/// coordinate mapping are testable without a live sim. The bridge IPC
/// and the JSON wrapping live in `PaneAccessibility`.
enum AXSweep {
    /// The two coordinate spaces one accessibility tree can occupy.
    ///
    /// `objectAtPoint:` hit-tests against the root element's own frame, and on
    /// nearly every device the children lay out inside exactly that rectangle,
    /// so one space serves both. A foldable's inner panel is the exception
    /// measured so far: its root reports the panel's portrait size while its
    /// children lay out turned 90° from it, which is also the way round the
    /// pane draws them. Keeping the two apart is what lets a point a viewer
    /// picked reach the element under it.
    struct TreeGeometry: Equatable {
        /// The root frame: where `objectAtPoint:` expects to be asked.
        let hitTest: CGSize
        /// Where the children lay out, which is what the pane shows.
        let viewer: CGSize

        /// Whether the two disagree by a quarter turn.
        var isTurned: Bool { viewer != hitTest }
    }

    /// What to do with one `elementAtPoint` throw inside the sweep
    /// loop. Routine misses (sparse AX coverage, blank canvas
    /// regions) skip and the loop continues; anything else is a
    /// systemic bridge failure and the sweep aborts so the caller
    /// can retry deliberately. Pure boolean choice: the caller
    /// owns the bridgeFailed construction.
    enum CellOutcome {
        case skip
        case fail
    }

    /// Minimum step the daemon honors. Anything finer is clamped up
    /// to `minStep`. This is a *bridge-cost ceiling*, not a tap-
    /// hittability floor. At 0.02 the grid maxes at 50×50 = 2500
    /// cells; at ~5ms per bridge call that's ~12s end-to-end,
    /// already past most CLI timeouts. Finer densities would
    /// monopolize the `PaneCoordinator` actor for minutes on end
    /// (0.002 → 250 000 cells → 20+ minutes) and block every other
    /// `pane.*` operation (input, close, subscribe) while running.
    /// The clamp is silent and the actually-used step is echoed back
    /// in the sweep response root so callers can see what they got.
    static let minStep: Double = 0.02

    /// Maximum step the daemon honors. Above this the grid is too
    /// coarse to catch HIG-minimum (44pt) tap targets reliably.
    static let maxStep: Double = 0.5

    /// Default step. ≈20pt on a 400pt-wide iPhone; ≈8.8pt on a 176pt
    /// watch. Hits HIG-minimum (44pt) tap targets reliably without
    /// blowing the 400-call ~2s budget.
    static let defaultStep: Double = 0.05

    /// Decide whether one error from `SimAccessibility.elementAtPoint`
    /// is a per-cell miss or a systemic failure. The bridge's
    /// `objectAtPointNil` (`code 78` in `SimAccessibilityErrorDomain`)
    /// is the expected outcome for blank pixels. Every other code
    /// (AXP load failure, translator missing, device-not-found,
    /// macPlatformElement nil, …) is treated as systemic.
    static func classify(error: Error) -> CellOutcome {
        let nsError = error as NSError
        if nsError.domain == SimAccessibilityErrorDomain,
            nsError.code == SimAccessibilityErrorCode.objectAtPointNil.rawValue {
            return .skip
        }
        return .fail
    }

    /// Clamp a caller-provided step into `[minStep, maxStep]`. `nil`
    /// or out-of-range values fall back to `defaultStep`.
    static func clampStep(_ requested: Double?) -> Double {
        guard let requested, requested.isFinite else { return defaultStep }
        return min(maxStep, max(minStep, requested))
    }

    /// Generate the grid of normalized coordinates the sweep queries.
    /// Sample-on-step from `(0,0)`; last sample on each axis is the
    /// largest `n*step` strictly less than `1.0`. Returns row-major
    /// (all xs at y=0, then all xs at y=step, …), since IPC ordering
    /// affects which element the dedup picks first when two cells
    /// resolve to the same one, and row-major is the conventional
    /// "top-left-down" reading direction.
    static func gridPoints(step: Double) -> [CGPoint] {
        let step = clampStep(step)
        var points: [CGPoint] = []
        // Use Int counts to avoid float-rounding drift across the axis.
        let count = Int((1.0 / step).rounded(.down))
        for row in 0...count {
            let y = Double(row) * step
            if y >= 1.0 { break }
            for col in 0...count {
                let x = Double(col) * step
                if x >= 1.0 { break }
                points.append(CGPoint(x: x, y: y))
            }
        }
        return points
    }

    /// Extract the frontmost app's interface size from a serialized
    /// `frontmostTree()` response. That app's root element is fullscreen
    /// on iOS and watchOS, so its `frame.{w, h}` spans the display.
    ///
    /// This is also the space `objectAtPoint:` hit-tests in, which is why
    /// `TreeGeometry` takes it as the hit-test rectangle. Returns nil when the
    /// tree carries no frame or a zero-sized one, leaving the caller to pick a
    /// degenerate stand-in rather than divide by zero.
    ///
    /// A non-finite dimension is rejected here too, and `> 0` does not cover
    /// it: an infinity passes that test, and every consumer then carries it
    /// somewhere it does real damage. Multiplied into a hit-test point it
    /// gives a coordinate no display holds; published as a divisor it reaches
    /// `JSONSerialization`, which raises an Objective-C exception no Swift
    /// `catch` sees.
    static func interfaceSize(fromTree tree: [String: Any]) -> CGSize? {
        guard let frame = tree["frame"] as? [String: Any] else { return nil }
        let width = (frame["w"] as? NSNumber)?.doubleValue ?? 0
        let height = (frame["h"] as? NSNumber)?.doubleValue ?? 0
        guard width > 0, height > 0, width.isFinite, height.isFinite else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Read both spaces out of a serialized `frontmostTree()` response.
    ///
    /// Treat the tree as turned when the descendants' right edge runs past the
    /// root's width and lands within a point of the root's height. That is a
    /// heuristic, not a guarantee: content falling short of the root, a dialog
    /// over a full-screen app, reads as unturned, and so does content merely
    /// wider than the root, a view that scrolls sideways.
    static func geometry(fromTree tree: [String: Any]) -> TreeGeometry? {
        guard let root = interfaceSize(fromTree: tree) else { return nil }
        let extent = contentExtent(ofChildrenIn: tree)
        // Descendant height is deliberately not checked: content scrolls, so
        // it overruns the visible axis on any list long enough to scroll.
        let turned = extent.width > root.width
            && abs(extent.width - root.height) <= 1
        return TreeGeometry(
            hitTest: root,
            viewer: turned ? CGSize(width: root.height, height: root.width) : root
        )
    }

    /// The furthest any descendant frame reaches. The root is excluded: it is
    /// the rectangle being compared against.
    private static func contentExtent(ofChildrenIn tree: [String: Any]) -> CGSize {
        var maximum = CGSize.zero
        func walk(_ node: [String: Any], isRoot: Bool) {
            if !isRoot, let frame = node["frame"] as? [String: Any] {
                let originX = (frame["x"] as? NSNumber)?.doubleValue ?? 0
                let originY = (frame["y"] as? NSNumber)?.doubleValue ?? 0
                let width = (frame["w"] as? NSNumber)?.doubleValue ?? 0
                let height = (frame["h"] as? NSNumber)?.doubleValue ?? 0
                maximum.width = max(maximum.width, originX + width)
                maximum.height = max(maximum.height, originY + height)
            }
            for child in node["children"] as? [[String: Any]] ?? [] {
                walk(child, isRoot: false)
            }
        }
        walk(tree, isRoot: true)
        return maximum
    }

    /// Convert a normalized point in displayed space to the coordinate
    /// `objectAtPoint:` hit-tests against.
    ///
    /// Accessibility is asked in the tree's own space, which turns with the
    /// interface, so a displayed point needs no rotation into the panel. When
    /// the viewer and hit-test sizes agree it scales straight into the root
    /// rectangle; when they differ by a quarter turn it is placed in the
    /// viewer's space first and then turned into the hit-test one. Input verbs
    /// apply their surface mapping separately, through
    /// `Orientation.surfacePoint`.
    ///
    /// The result is clamped. A caller may legitimately supply `1.0`, and
    /// turning a sampled zero edge can map it to the far hit-test boundary,
    /// which sits one past the last coordinate any frame contains.
    static func hitTestPoint(displayed point: CGPoint, geometry: TreeGeometry) -> CGPoint {
        let viewer = geometry.viewer
        let hit = geometry.hitTest
        let placed = CGPoint(
            x: Double(point.x) * Double(viewer.width),
            y: Double(point.y) * Double(viewer.height)
        )
        let mapped = geometry.isTurned
            ? CGPoint(x: placed.y, y: Double(viewer.width) - placed.x)
            : placed
        return CGPoint(
            x: clampedToPanel(Double(mapped.x), extent: Double(hit.width)),
            y: clampedToPanel(Double(mapped.y), extent: Double(hit.height))
        )
    }

    /// Clamp one axis into the half-open `[0, extent)` the panel
    /// occupies. `CGRect` containment excludes the far edge, so `extent`
    /// itself hit-tests against nothing.
    private static func clampedToPanel(_ value: Double, extent: Double) -> Double {
        guard extent > 0 else { return 0 }
        return min(max(value, 0), extent.nextDown)
    }

    /// Canonical dedup key for an element dict the bridge returned
    /// from `elementAtPoint`. Combines role + identifier + label +
    /// frame so the same element queried from N adjacent grid points
    /// collapses to one row in the sweep output. Missing keys are
    /// rendered as empty so `nil` and `""` produce the same key
    /// (which is what the bridge's `_populate` writes anyway: it
    /// omits empty strings, so `nil`-vs-`""` is impossible in
    /// practice from the bridge, but the defensiveness costs nothing).
    static func dedupKey(element: [String: Any]) -> String {
        let role = (element["role"] as? String) ?? ""
        let ident = (element["identifier"] as? String) ?? ""
        let label = (element["label"] as? String) ?? ""
        let frame = element["frame"] as? [String: Any] ?? [:]
        let frameX = (frame["x"] as? NSNumber)?.doubleValue ?? 0
        let frameY = (frame["y"] as? NSNumber)?.doubleValue ?? 0
        let frameW = (frame["w"] as? NSNumber)?.doubleValue ?? 0
        let frameH = (frame["h"] as? NSNumber)?.doubleValue ?? 0
        return "\(role)|\(ident)|\(label)|\(frameX),\(frameY),\(frameW),\(frameH)"
    }
}
