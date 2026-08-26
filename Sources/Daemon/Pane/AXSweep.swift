// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreSimulatorBridge
import DaemonProtocol
import Foundation

/// Pure math behind `pane.ax.point` and `pane.ax.sweep`: the grid the
/// sweep walks, the key that collapses it to unique elements, the
/// per-cell error classifier, and the displayed-to-native coordinate
/// conversion both verbs hand the bridge. `pane.ax.tree` addresses no
/// point and uses none of it.
///
/// Kept out of `PaneCoordinator` so grid density, dedup uniqueness, and
/// coordinate mapping are testable without a live sim. The bridge IPC
/// and the JSON wrapping live in `PaneAccessibility`.
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

    /// Deadline after which the sweep starts no further bridge calls.
    ///
    /// `minStep` admits a 2500-cell grid, which at the bridge's per-call
    /// cost can exceed an ordinary request deadline. Undeadlined, the walk
    /// keeps querying long after the caller stopped listening, and it holds
    /// the pane's accessibility queue the whole time, so the next `ax` read
    /// or the verb behind it waits out a result nobody wants. Answering
    /// short gives the caller something to act on and gives the queue back.
    ///
    /// The CLI leaves five seconds of headroom beyond this, so the daemon
    /// normally answers first.
    static let maxDurationMs: Int = 10_000

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
    /// This is the size of the interface as presented, not the display
    /// panel's own: in landscape the two are transposed, which is why
    /// `nativePixel(displayed:orientation:interface:)` takes an
    /// orientation as well. Returns nil when the tree carries no frame
    /// or a zero-sized one, leaving the caller to pick a degenerate
    /// stand-in rather than divide by zero.
    static func interfaceSize(fromTree tree: [String: Any]) -> CGSize? {
        guard let frame = tree["frame"] as? [String: Any] else { return nil }
        let width = (frame["w"] as? NSNumber)?.doubleValue ?? 0
        let height = (frame["h"] as? NSNumber)?.doubleValue ?? 0
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// The display panel's own size, given the interface size the
    /// accessibility tree reported and the orientation the pane is
    /// presenting at.
    ///
    /// CoreSimulator holds the panel at the device's portrait
    /// dimensions however the device is turned, while the accessibility
    /// tree measures the app's interface, which turns with it. The two
    /// agree in portrait and transpose in landscape.
    static func nativeSize(interface size: CGSize, orientation: Orientation) -> CGSize {
        switch orientation {
        case .landscapeLeft, .landscapeRight:
            return CGSize(width: size.height, height: size.width)

        case .portrait, .portraitUpsideDown:
            return size
        }
    }

    /// Convert a normalized point in displayed space to the panel
    /// coordinate AXPTranslator's `objectAtPoint:` hit-tests against.
    ///
    /// Rotate the point into the panel's frame, then scale by the
    /// panel's size rather than by the interface size the tree reported.
    /// Scaling a rotated point by the interface size divides each axis by
    /// the other axis's length, so in landscape a legal coordinate
    /// resolves the wrong element or none at all.
    ///
    /// The result is clamped to the panel. Every orientation but portrait
    /// sends some displayed boundary to exactly `1.0`, one past the last
    /// coordinate a frame contains: the top edge under landscape-left,
    /// the left edge under landscape-right, both upside-down. Those are
    /// coordinates the grid emits and a caller can legitimately ask for,
    /// so without the clamp they would hit nothing.
    static func nativePixel(
        displayed point: CGPoint,
        orientation: Orientation,
        interface size: CGSize
    ) -> CGPoint {
        let native = nativeSize(interface: size, orientation: orientation)
        let rotated = orientation.surfacePoint(
            displayedX: Double(point.x),
            displayedY: Double(point.y)
        )
        return CGPoint(
            x: clampedToPanel(rotated.x * Double(native.width), extent: Double(native.width)),
            y: clampedToPanel(rotated.y * Double(native.height), extent: Double(native.height))
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
