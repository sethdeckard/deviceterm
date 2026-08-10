// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimGestureMath: pure geometry + multi-touch synthesis for the
// simulator pane, extracted from SimulatorContentView. No
// AppKit/responder state: the letterbox mapping, tap/swipe
// classification, and pinch/rotate finger synthesis are pure so they
// can be unit-tested in isolation. The view keeps the NSResponder event
// handlers (input dispatch must live on the responder) and calls these.
//
// The formulas were established empirically against a live simulator,
// so the golden tests pin them exactly rather than re-deriving them.

import CoreGraphics
import DaemonProtocol

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
    /// `orientation` mirrors the render-side UV rotation in
    /// `SimulatorContentView`: when the device is landscape we
    /// compute aspect-fit against a width/height-swapped effective
    /// surface (so the letterbox rect matches the displayed quad)
    /// AND rotate the resulting unit-square coordinate back into
    /// the original portrait surface space (so the daemon's HID,
    /// which always speaks the IOSurface's fixed portrait
    /// orientation, gets the equivalent tap location on the
    /// device's native screen). Without that round-trip, a tap on
    /// the visible top-left of landscape Maps would normalize to
    /// the portrait surface's top-left, which after the device's
    /// rotation lands somewhere off-screen.
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
        // Normalized in the *displayed* (oriented) coordinate
        // space.
        let oriented = CGPoint(
            x: (viewPoint.x - rect.origin.x) / rect.width,
            y: (viewPoint.y - rect.origin.y) / rect.height
        )
        return rotateOrientedToSurface(oriented, orientation: orientation)
    }

    /// Map a point in view coordinates to a normalized surface
    /// coordinate, allowing values outside [0,1] when the point is
    /// in the bezel area (above / below / beside the rendered
    /// screen). Same orientation-aware letterbox math as
    /// `normalizedPoint`, but never returns nil and never clamps, since
    /// the daemon's HID contract already accepts out-of-range
    /// coords as off-screen gestures (`Sources/Daemon/PaneMethods
    /// .swift` TapParams/SwipeParams).
    ///
    /// This is the path the iOS app-switcher swipe rides on:
    /// pressing the bezel just below the screen produces a touch
    /// at y > 1 in the portrait surface frame, and the cross-edge
    /// trajectory into the screen is what the swipe-up gesture
    /// needs to register.
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
        let oriented = CGPoint(
            x: (viewPoint.x - rect.origin.x) / rect.width,
            y: (viewPoint.y - rect.origin.y) / rect.height
        )
        return rotateOrientedToSurface(oriented, orientation: orientation)
    }

    /// Map a point in view coordinates to the **oriented (displayed)**
    /// unit-square coordinate: the same intermediate
    /// `extendedNormalizedPoint` computes *before*
    /// `rotateOrientedToSurface`. Unclamped and never nil except on
    /// degenerate geometry, so a bezel-origin point just below the screen
    /// reads as `y` slightly > 1.
    ///
    /// This is what bottom-edge-band detection keys on: in displayed
    /// space the home-indicator strip is always near `y = 1` regardless of
    /// device orientation (iOS renders it at the bottom of the current
    /// interface orientation), whereas the post-rotation *surface* point
    /// lands on a different edge per orientation. So we test the band here,
    /// then let the surface coords flow through `extendedNormalizedPoint`
    /// unchanged.
    static func orientedNormalizedPoint(
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
    /// is the `y` from `orientedNormalizedPoint`.
    static func isInBottomEdgeBand(orientedY: CGFloat) -> Bool {
        orientedY >= AppSwitcherGesture.bottomEdgeBandMinY
    }

    /// Map a unit-square coordinate from the displayed
    /// (orientation-applied) space to the original portrait surface
    /// space. This must reproduce the *same* displayed->surface mapping
    /// the render shader applies (`SimulatorContentView.uvRotation`): the
    /// shader picks, for each displayed point, the surface texel to show
    /// there, so a tap injects the touch at exactly that texel. Portrait
    /// and upside-down are self-inverse (180deg / identity), so they need
    /// no per-orientation distinction; the two landscape rotations are
    /// 90deg opposites of each other. Pure math, exposed so the tests can
    /// pin every corner without going through the view.
    static func rotateOrientedToSurface(
        _ point: CGPoint,
        orientation: Orientation
    ) -> CGPoint {
        switch orientation {
        case .portrait:
            return point

        case .landscapeLeft:
            // displayed top-left (0,0) -> portrait bottom-left's surface (1,0)
            return CGPoint(x: 1 - point.y, y: point.x)

        case .portraitUpsideDown:
            return CGPoint(x: 1 - point.x, y: 1 - point.y)

        case .landscapeRight:
            // displayed top-left (0,0) -> portrait top-right's surface (0,1)
            return CGPoint(x: point.y, y: 1 - point.x)
        }
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
