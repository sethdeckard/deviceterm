// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreSimulatorBridge
import Foundation

/// Pure math for `pane.ax.sweep`. Pieces:
///
///   1. `gridPoints(step:)`, the grid of normalized [0,1)² coordinates
///      the daemon walks. The daemon scales each one to pixels (via
///      `pixelPoint(normalized:screen:)`) before handing to the bridge,
///      so the grid stays portable across device families. Generator
///      is sample-on-step (anchor at 0); last sample on each axis is
///      the largest `n*step < 1.0`.
///
///   2. `dedupKey(element:)`, the canonical key for collapsing the N
///      cells × ~1 element per cell into the unique-element set.
///      Combines role + identifier + label + frame so two grid points
///      that hit the same element produce identical keys and elements
///      that genuinely differ (same role + identifier + frame, different
///      label = mid-transition state change) keep both. Order-stable
///      "first sighting wins" is the responsibility of the caller's
///      collect loop, not this helper.
///
///   3. `screenSize(fromTree:)` + `pixelPoint(normalized:screen:)`,
///      the normalized-to-pixel conversion. AXPTranslator's
///      `objectAtPoint:displayId:bridgeDelegateToken:` takes absolute
///      display-space pixel coordinates, *not* the normalized or
///      view-relative coordinates the rest of this file deals in.
///      Callers fetch `frontmostTree()` once per request, extract the
///      root frame's pixel dimensions, then scale each normalized
///      grid point into that pixel frame before the bridge call.
///      Without this conversion the sweep walks sub-pixel coordinates
///      near `(0,0)` on every device and returns empty `children`
///      regardless of what's on screen.
///
/// Split out of `PaneCoordinator.accessibilitySweep(paneId:step:)` per
/// AGENTS.md's "pure math namespaces / decision types" convention so the
/// matrix (grid density, dedup uniqueness, coord scaling) is unit-
/// testable without a live sim. The bridge IPC + JSON wrapping stay in
/// PaneCoordinator.
enum AXSweep {
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

    /// Extract the device's screen pixel size from a serialized
    /// `frontmostTree()` response. The root element of the frontmost
    /// app is fullscreen on iOS/watchOS, so its `frame.{w, h}` is the
    /// authoritative screen size for the currently-attached display.
    /// Returns nil if the tree has no frame or zero-sized dimensions
    /// (caller should fall back to treating the input as already
    /// pixel-space, the historical behavior, rather than dividing by
    /// zero or scaling to nothing).
    static func screenSize(fromTree tree: [String: Any]) -> CGSize? {
        guard let frame = tree["frame"] as? [String: Any] else { return nil }
        let width = (frame["w"] as? NSNumber)?.doubleValue ?? 0
        let height = (frame["h"] as? NSNumber)?.doubleValue ?? 0
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Scale a normalized [0,1] point to pixel coordinates within the
    /// given screen size. Used to bridge the daemon's normalized RPC
    /// surface to AXPTranslator's pixel-space `objectAtPoint:`. The
    /// upper bound `1.0` maps to `screen.width / .height` exactly;
    /// `gridPoints(step:)` never emits `1.0` so the bridge never sees
    /// a coord at the half-open screen edge.
    static func pixelPoint(normalized: CGPoint, screen: CGSize) -> CGPoint {
        CGPoint(x: normalized.x * screen.width, y: normalized.y * screen.height)
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
