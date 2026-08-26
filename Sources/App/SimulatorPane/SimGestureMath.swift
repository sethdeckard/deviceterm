// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol

/// Pure geometry + multi-touch synthesis for the
/// simulator pane, extracted from SimulatorContentView. No
/// AppKit/responder state: the letterbox mapping, tap/swipe
/// classification, and pinch/rotate finger synthesis are pure so they
/// can be unit-tested in isolation. The view keeps the NSResponder event
/// handlers (input dispatch must live on the responder) and calls these.
///
/// The formulas were established empirically against a live simulator,
/// so the golden tests pin them exactly rather than re-deriving them.
enum SimGestureMath {
    /// Initial half-separation between the two synthesized fingers when a
    /// pinch/rotate begins.
    static let pinchInitialSeparation: CGFloat = 0.12
    /// Below this normalized travel a drag is treated as a tap, not swipe.
    static let tapDragThreshold: CGFloat = 0.01
    /// Clamp range for the synthesized finger separation.
    static let separationRange: ClosedRange<CGFloat> = 0.02...0.6

    /// The aspect-fit image rect inside `viewSize`: the screen
    /// region the IOSurface renders into after the shader's
    /// letterbox math. Exposed so callers that need to know "where
    /// is the screen?" (bezel painting, edge-gesture hit testing)
    /// can reuse the same computation the shader and gesture math
    /// already share. Returns nil when either size is degenerate.
    ///
    /// `displayInset` reserves margin on each side of `viewSize`
    /// for the device-frame bezel. The screen aspect-fits inside
    /// `viewSize` reduced by `2 × displayInset` on each axis and
    /// the returned rect is centered back in the original
    /// `viewSize` coordinate space, so the bezel can paint a
    /// `displayInset`-wide strip around the screen without
    /// overflowing the pane.
    static func imageRect(
        viewSize: CGSize,
        surfaceSize: CGSize,
        orientation: Orientation = .portrait,
        displayInset: CGFloat = 0
    ) -> CGRect? {
        guard surfaceSize.width > 0, surfaceSize.height > 0,
            viewSize.width > 0, viewSize.height > 0 else { return nil }
        let usableWidth = max(1, viewSize.width - 2 * displayInset)
        let usableHeight = max(1, viewSize.height - 2 * displayInset)
        // Effective surface (what's actually displayed), swapped
        // for landscape so the aspect-fit letterbox matches the
        // rotated quad on screen.
        let isLandscape = orientation == .landscapeLeft
            || orientation == .landscapeRight
        let effectiveSurface = isLandscape
            ? CGSize(width: surfaceSize.height, height: surfaceSize.width)
            : surfaceSize
        let imageAspect = effectiveSurface.width / effectiveSurface.height
        let usableAspect = usableWidth / usableHeight
        let screenWidth: CGFloat
        let screenHeight: CGFloat
        if usableAspect > imageAspect {
            screenHeight = usableHeight
            screenWidth = usableHeight * imageAspect
        } else {
            screenWidth = usableWidth
            screenHeight = usableWidth / imageAspect
        }
        return CGRect(
            x: (viewSize.width - screenWidth) / 2,
            y: (viewSize.height - screenHeight) / 2,
            width: screenWidth,
            height: screenHeight
        )
    }

    /// Map a point in view coordinates to (0..1) within the aspect-fit
    /// rendered image, or nil if outside the letterboxed image.
    ///
    /// The result is in **displayed** space, which is what the
    /// coordinate-bearing touch verbs take: `(0, 0)` is the top-left of
    /// what the viewer sees. The daemon rotates it into the device's
    /// native portrait surface at its input boundary, resolving against
    /// the presentation orientation it holds there
    /// (`Orientation.surfacePoint(displayedX:displayedY:)`).
    ///
    /// `orientation` is still needed here, for the letterbox: a
    /// landscape device aspect-fits against a width/height-swapped
    /// effective surface so the rect matches the displayed quad.
    static func normalizedPoint(
        viewPoint: CGPoint,
        viewSize: CGSize,
        surfaceSize: CGSize,
        orientation: Orientation = .portrait,
        displayInset: CGFloat = 0
    ) -> CGPoint? {
        guard let rect = imageRect(
            viewSize: viewSize,
            surfaceSize: surfaceSize,
            orientation: orientation,
            displayInset: displayInset
        ) else { return nil }
        guard rect.contains(viewPoint) else { return nil }
        return CGPoint(
            x: (viewPoint.x - rect.origin.x) / rect.width,
            y: (viewPoint.y - rect.origin.y) / rect.height
        )
    }

    /// Map a point in view coordinates to a **displayed**-space
    /// coordinate, allowing values outside [0,1] when the point is in
    /// the bezel area (above / below / beside the rendered screen).
    /// Same letterbox math as `normalizedPoint`, but never returns nil
    /// and never clamps, since the daemon's HID contract already accepts
    /// out-of-range coords as off-screen gestures.
    ///
    /// This is the path the iOS app-switcher swipe rides on: pressing
    /// the bezel just below the screen produces a touch at `y > 1`, and
    /// the cross-edge trajectory into the screen is what the swipe-up
    /// gesture needs to register. In displayed space the home-indicator
    /// strip is near `y = 1` in every orientation, which is what
    /// `isInBottomEdgeBand` keys on.
    static func extendedNormalizedPoint(
        viewPoint: CGPoint,
        viewSize: CGSize,
        surfaceSize: CGSize,
        orientation: Orientation = .portrait,
        displayInset: CGFloat = 0
    ) -> CGPoint? {
        guard let rect = imageRect(
            viewSize: viewSize,
            surfaceSize: surfaceSize,
            orientation: orientation,
            displayInset: displayInset
        ) else { return nil }
        return CGPoint(
            x: (viewPoint.x - rect.origin.x) / rect.width,
            y: (viewPoint.y - rect.origin.y) / rect.height
        )
    }

    /// Whether a displayed-space (oriented) unit-Y sits in the bottom-edge
    /// band that arms the home / App-Switcher system gesture. `orientedY`
    /// is the `y` from `extendedNormalizedPoint`.
    static func isInBottomEdgeBand(orientedY: CGFloat) -> Bool {
        orientedY >= AppSwitcherGesture.bottomEdgeBandMinY
    }

    /// Fallback for a release point outside the letterbox: map raw view
    /// coordinates straight into the unit square.
    static func unitClamped(viewPoint: CGPoint, viewSize: CGSize) -> CGPoint {
        CGPoint(
            x: max(0, min(1, viewPoint.x / max(1, viewSize.width))),
            y: max(0, min(1, viewPoint.y / max(1, viewSize.height)))
        )
    }

    /// Whether a drag from `start` to `end` (both normalized) is a tap.
    static func isTap(from start: CGPoint, to end: CGPoint) -> Bool {
        hypot(end.x - start.x, end.y - start.y) < tapDragThreshold
    }

    /// Two synthesized finger positions for a pinch/rotate centered at
    /// `center`, `separation` apart, rotated `angle` radians.
    static func fingers(
        center: CGPoint,
        separation: CGFloat,
        angle: CGFloat
    ) -> (CGPoint, CGPoint) {
        let deltaX = separation * cos(angle)
        let deltaY = separation * sin(angle)
        return (
            CGPoint(x: center.x - deltaX, y: center.y - deltaY),
            CGPoint(x: center.x + deltaX, y: center.y + deltaY)
        )
    }

    /// Point-reflection of `current` through `anchor`: the mirrored
    /// second finger for live Option-drag multitouch. With the anchor at
    /// screen center, `current` is finger 1 (the mouse) and the result
    /// is finger 2; the separation is `2·distance(current, anchor)`, so
    /// moving toward the anchor pinches in (zoom out) and away pinches
    /// out (zoom in), while orbiting the anchor rotates the pair.
    ///
    /// Deliberately NOT clamped: a mirrored finger can land outside
    /// `[0,1]` at large separations, and the daemon HID contract accepts
    /// off-range coords as off-screen (same as `extendedNormalizedPoint`).
    static func mirroredPoint(anchor: CGPoint, current: CGPoint) -> CGPoint {
        CGPoint(x: anchor.x * 2 - current.x, y: anchor.y * 2 - current.y)
    }

    /// Apply a multiplicative magnification step to the separation and
    /// clamp to `separationRange`.
    static func scaledSeparation(
        _ separation: CGFloat,
        by factor: CGFloat
    ) -> CGFloat {
        min(
            separationRange.upperBound,
            max(separationRange.lowerBound, separation * (1 + factor))
            )
    }

    /// Map an `NSEvent.scrollingDeltaY` (pixels) into a crown delta
    /// in the bridge's raw unit (~1 unit per detent). Precision
    /// scrolls (trackpad / Magic Mouse) get a smaller multiplier so
    /// a trackpad stroke doesn't blow past the crown's usable range;
    /// non-precision (mechanical scroll wheel) scrolls pass through
    /// as one detent per notch. Sign is preserved; the caller decides
    /// whether to invert for natural-scroll semantics.
    static func crownDelta(scrollingDeltaY: Double, precision: Bool) -> Double {
        precision ? scrollingDeltaY * 0.1 : scrollingDeltaY
    }
}
