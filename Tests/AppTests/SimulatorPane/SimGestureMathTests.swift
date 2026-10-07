// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import CoreGraphics
import DaemonProtocol
import Testing

/// Golden cases for the pure gesture math extracted from
/// SimulatorContentView. Letterbox mapping (both aspect branches),
/// out-of-image rejection, the unit-clamp fallback, tap/swipe
/// classification, finger synthesis, and separation clamping.
struct SimGestureMathTests {
    private func approxEqual(
        _ lhs: CGPoint,
        _ rhs: CGPoint,
        _ eps: CGFloat = 1e-9
    ) -> Bool {
        abs(lhs.x - rhs.x) < eps && abs(lhs.y - rhs.y) < eps
    }

    @Test
    func normalizedPointPillarboxedPortrait() throws {
        // Tall surface in a square view → left/right letterbox at x∈[25,75].
        let size = CGSize(width: 100, height: 100)
        let surface = CGSize(width: 100, height: 200)
        let center = try #require(
            SimGestureMath.normalizedPoint(
            viewPoint: CGPoint(x: 50, y: 50),
            viewSize: size,
            surfaceSize: surface
        )
            )
        #expect(approxEqual(center, CGPoint(x: 0.5, y: 0.5)))
        // Interior point near the bottom-right (the max edge itself is
        // excluded by CGRect.contains).
        let offCenter = try #require(
            SimGestureMath.normalizedPoint(
            viewPoint: CGPoint(x: 70, y: 80),
            viewSize: size,
            surfaceSize: surface
        )
            )
        #expect(approxEqual(offCenter, CGPoint(x: 0.9, y: 0.8)))
        // x=10 is in the left letterbox → outside the image.
        #expect(
            SimGestureMath.normalizedPoint(
            viewPoint: CGPoint(x: 10, y: 50),
            viewSize: size,
            surfaceSize: surface
        ) == nil
            )
    }

    @Test
    func normalizedPointLetterboxedLandscape() throws {
        // Wide surface in a square view → top/bottom letterbox at y∈[25,75].
        let size = CGSize(width: 100, height: 100)
        let surface = CGSize(width: 200, height: 100)
        let center = try #require(
            SimGestureMath.normalizedPoint(
            viewPoint: CGPoint(x: 50, y: 50),
            viewSize: size,
            surfaceSize: surface
        )
            )
        #expect(approxEqual(center, CGPoint(x: 0.5, y: 0.5)))
        #expect(
            SimGestureMath.normalizedPoint(
            viewPoint: CGPoint(x: 50, y: 10),
            viewSize: size,
            surfaceSize: surface
        ) == nil
            )
    }

    @Test
    func extendedPointReportsDisplayedY() throws {
        // Surface matches the view aspect → the image fills the view, so
        // displayed-Y maps straight to viewPoint.y / height.
        let size = CGSize(width: 100, height: 200)
        let surface = CGSize(width: 100, height: 200)
        // Just above the bottom edge → oriented y ~0.98.
        let nearBottom = try #require(
            SimGestureMath.extendedNormalizedPoint(
            viewPoint: CGPoint(x: 50, y: 196),
            viewSize: size,
            surfaceSize: surface
        )
            )
        #expect(approxEqual(nearBottom, CGPoint(x: 0.5, y: 0.98)))
        // A bezel point *below* the screen reads unclamped (y > 1), since the
        // bottom-edge drag can originate there.
        let belowScreen = try #require(
            SimGestureMath.extendedNormalizedPoint(
            viewPoint: CGPoint(x: 50, y: 210),
            viewSize: size,
            surfaceSize: surface
        )
            )
        #expect(belowScreen.y > 1)
    }

    @Test
    func bottomEdgeBandIncludesEdgeAndBezelButNotMidScreen() {
        #expect(SimGestureMath.isInBottomEdgeBand(orientedY: 0.96))
        #expect(SimGestureMath.isInBottomEdgeBand(orientedY: 0.99))
        #expect(SimGestureMath.isInBottomEdgeBand(orientedY: 1.05))   // bezel
        #expect(!SimGestureMath.isInBottomEdgeBand(orientedY: 0.95))
        #expect(!SimGestureMath.isInBottomEdgeBand(orientedY: 0.5))
    }

    @Test("App Switcher edge map is the live-confirmed per-orientation set")
    func appSwitcherEdgeMap() {
        // The edge value rotates with orientation.
        #expect(AppSwitcherGesture.edge(for: .portrait) == 3)
        #expect(AppSwitcherGesture.edge(for: .landscapeLeft) == 2)
        #expect(AppSwitcherGesture.edge(for: .landscapeRight) == 4)
        // Upside-down has no home-gesture edge (all values swept, none
        // armed the recognizer) → nil, so the caller degrades to a plain
        // touch instead of guessing.
        #expect(AppSwitcherGesture.edge(for: .portraitUpsideDown) == nil)
    }

    @Test
    func normalizedPointRejectsDegenerateSizes() {
        let size = CGSize(width: 100, height: 100)
        #expect(
            SimGestureMath.normalizedPoint(
            viewPoint: .zero,
            viewSize: size,
            surfaceSize: .zero
        ) == nil
            )
        #expect(
            SimGestureMath.normalizedPoint(
            viewPoint: .zero,
            viewSize: .zero,
            surfaceSize: CGSize(width: 100, height: 200)
        ) == nil
            )
    }

    @Test
    func unitClampedMapsAndClamps() {
        let size = CGSize(width: 100, height: 100)
        #expect(
            approxEqual(
            SimGestureMath.unitClamped(viewPoint: CGPoint(x: 50, y: 50), viewSize: size),
            CGPoint(x: 0.5, y: 0.5)
        )
            )
        #expect(
            approxEqual(
            SimGestureMath.unitClamped(viewPoint: CGPoint(x: -10, y: 200), viewSize: size),
            CGPoint(x: 0, y: 1)
        )
            )
    }

    @Test
    func tapVsSwipeThreshold() {
        let origin = CGPoint(x: 0.5, y: 0.5)
        #expect(SimGestureMath.isTap(from: origin, to: CGPoint(x: 0.505, y: 0.5)))
        #expect(!SimGestureMath.isTap(from: origin, to: CGPoint(x: 0.52, y: 0.5)))
    }

    @Test
    func fingerSynthesis() {
        let center = CGPoint(x: 0.5, y: 0.5)
        let (left, right) = SimGestureMath.fingers(
            center: center,
            separation: 0.1,
            angle: 0
        )
        #expect(approxEqual(left, CGPoint(x: 0.4, y: 0.5)))
        #expect(approxEqual(right, CGPoint(x: 0.6, y: 0.5)))
        let (lower, upper) = SimGestureMath.fingers(
            center: center,
            separation: 0.1,
            angle: .pi / 2
        )
        #expect(approxEqual(lower, CGPoint(x: 0.5, y: 0.4)))
        #expect(approxEqual(upper, CGPoint(x: 0.5, y: 0.6)))
    }

    @Test
    func mirroredPointReflectsThroughAnchor() {
        let center = CGPoint(x: 0.5, y: 0.5)
        // Mouse offset from center → mirror is the opposite offset.
        #expect(approxEqual(
            SimGestureMath.mirroredPoint(anchor: center, current: CGPoint(x: 0.7, y: 0.5)),
            CGPoint(x: 0.3, y: 0.5)
        ))
        // Orbit (diagonal) reflects on both axes.
        #expect(approxEqual(
            SimGestureMath.mirroredPoint(anchor: center, current: CGPoint(x: 0.7, y: 0.8)),
            CGPoint(x: 0.3, y: 0.2)
        ))
    }

    @Test
    func mirroredPointAtAnchorIsDegenerate() {
        let center = CGPoint(x: 0.5, y: 0.5)
        // current == anchor → mirror == anchor (zero separation).
        #expect(approxEqual(
            SimGestureMath.mirroredPoint(anchor: center, current: center),
            center
        ))
    }

    @Test
    func mirroredPointIsNotClampedOffScreen() {
        // Large separation about a non-center anchor → off-[0,1] mirror,
        // intentionally not clamped (daemon HID accepts off-range coords).
        let mirror = SimGestureMath.mirroredPoint(
            anchor: CGPoint(x: 0.3, y: 0.3),
            current: CGPoint(x: 0.9, y: 0.9)
        )
        #expect(approxEqual(mirror, CGPoint(x: -0.3, y: -0.3)))
    }

    @Test
    func separationClamps() {
        #expect(SimGestureMath.scaledSeparation(0.1, by: 0) == 0.1)
        #expect(SimGestureMath.scaledSeparation(0.1, by: 1) == 0.2)
        #expect(SimGestureMath.scaledSeparation(0.5, by: 1) == 0.6)     // clamped high
        #expect(SimGestureMath.scaledSeparation(0.02, by: -1) == 0.02)  // clamped low
    }

    // MARK: - crownDelta

    @Test
    func crownDeltaScalesPrecisionScrolls() {
        // Trackpad / Magic Mouse: precision deltas come in as small
        // pixel values (~1-10 per step); scaling by 0.1 keeps a
        // single trackpad stroke from blowing past the crown's
        // usable range. A 50pt precision swipe is ~5 crown units,
        // half the watch's typical scroll range per the CLI's
        // `deviceterm crown 5` reference.
        #expect(
            SimGestureMath.crownDelta(
            scrollingDeltaY: 50,
            precision: true
        ) == 5
            )
        #expect(
            SimGestureMath.crownDelta(
            scrollingDeltaY: 10,
            precision: true
        ) == 1
            )
        #expect(
            SimGestureMath.crownDelta(
            scrollingDeltaY: 0,
            precision: true
        ) == 0
            )
    }

    @Test
    func crownDeltaPassesMechanicalDeltasThrough() {
        // Mechanical scroll wheel: deltas are detent-sized (1-3 per
        // notch); pass through 1:1 so each notch is one crown unit.
        #expect(
            SimGestureMath.crownDelta(
            scrollingDeltaY: 1,
            precision: false
        ) == 1
            )
        #expect(
            SimGestureMath.crownDelta(
            scrollingDeltaY: 3,
            precision: false
        ) == 3
            )
    }

    @Test
    func crownDeltaPreservesSign() {
        // Sign carries direction (positive = forward / down per the
        // daemon's crown contract). Inverting for natural-scroll
        // semantics is the caller's call, not the math helper's.
        #expect(
            SimGestureMath.crownDelta(
            scrollingDeltaY: -50,
            precision: true
        ) == -5
            )
        #expect(
            SimGestureMath.crownDelta(
            scrollingDeltaY: -2,
            precision: false
        ) == -2
            )
    }

    // MARK: - Orientation-aware normalization

    /// Identity round-trip on portrait: interior points map
    /// straight through. (Corners use slightly-interior values
    /// because `CGRect.contains` excludes the bottom/right edges.)
    @Test
    func portraitNormalizationPreservesInteriorPoints() {
        let view = CGSize(width: 200, height: 400)
        let surface = CGSize(width: 200, height: 400)  // same aspect
        let nearOrigin = SimGestureMath.normalizedPoint(
            viewPoint: CGPoint(x: 1, y: 1),
            viewSize: view,
            surfaceSize: surface,
            orientation: .portrait
        )
        let center = SimGestureMath.normalizedPoint(
            viewPoint: CGPoint(x: 100, y: 200),
            viewSize: view,
            surfaceSize: surface,
            orientation: .portrait
        )
        #expect(abs((nearOrigin?.x ?? -1) - 0.005) < 1e-9)
        #expect(abs((nearOrigin?.y ?? -1) - 0.0025) < 1e-9)
        #expect(center == CGPoint(x: 0.5, y: 0.5))
    }

    // MARK: - imageRect (shared with shader + bezel math)

    @Test
    func imageRectPortraitInWideView() throws {
        // Tall surface in a square view → vertical bars at x∈[0,25)
        // and [75,100], image rect at x∈[25,75], full height.
        let rect = try #require(
            SimGestureMath.imageRect(
                viewSize: CGSize(width: 100, height: 100),
                surfaceSize: CGSize(width: 100, height: 200)
            )
        )
        #expect(rect == CGRect(x: 25, y: 0, width: 50, height: 100))
    }

    @Test
    func imageRectIsNilForDegenerateInputs() {
        #expect(
            SimGestureMath.imageRect(
                viewSize: .zero,
                surfaceSize: CGSize(width: 100, height: 200)
            ) == nil
        )
        #expect(
            SimGestureMath.imageRect(
                viewSize: CGSize(width: 100, height: 100),
                surfaceSize: .zero
            ) == nil
        )
    }

    // MARK: - extendedNormalizedPoint (off-screen gesture starts)

    @Test
    func extendedPointBelowScreenProducesYGreaterThanOne() throws {
        // Pillarboxed portrait: image rect at x∈[25,75], y∈[0,100].
        // A click 20pt below the bottom edge (y=120) should produce
        // y > 1 in the portrait surface frame, which the daemon accepts
        // it as an off-screen touch for the app-switcher swipe.
        let point = try #require(
            SimGestureMath.extendedNormalizedPoint(
                viewPoint: CGPoint(x: 50, y: 120),
                viewSize: CGSize(width: 100, height: 100),
                surfaceSize: CGSize(width: 100, height: 200)
            )
        )
        #expect(point.x == 0.5)
        #expect(point.y == 1.2)
    }

    @Test
    func extendedPointAboveScreenProducesNegativeY() throws {
        // Same pillarbox; a click 10pt above the top edge (y=-10)
        // produces y < 0, for swipe-from-status-bar gestures.
        let point = try #require(
            SimGestureMath.extendedNormalizedPoint(
                viewPoint: CGPoint(x: 50, y: -10),
                viewSize: CGSize(width: 100, height: 100),
                surfaceSize: CGSize(width: 100, height: 200)
            )
        )
        #expect(point.x == 0.5)
        #expect(point.y == -0.1)
    }

    @Test
    func extendedPointBesideScreenProducesXOutsideUnit() throws {
        // Image rect at x∈[25,75]; a click at x=15 (left of the
        // screen) produces x < 0; x=85 produces x > 1.
        let left = try #require(
            SimGestureMath.extendedNormalizedPoint(
                viewPoint: CGPoint(x: 15, y: 50),
                viewSize: CGSize(width: 100, height: 100),
                surfaceSize: CGSize(width: 100, height: 200)
            )
        )
        let right = try #require(
            SimGestureMath.extendedNormalizedPoint(
                viewPoint: CGPoint(x: 85, y: 50),
                viewSize: CGSize(width: 100, height: 100),
                surfaceSize: CGSize(width: 100, height: 200)
            )
        )
        #expect(left.x == -0.2)
        #expect(right.x == 1.2)
    }

    @Test
    func extendedPointUsesTheLandscapeLetterbox() throws {
        // landscapeLeft: portrait surface 100×200 rendered rotated, so
        // the aspect-fit runs against a swapped 200×100 effective
        // surface and the image fills viewSize exactly. A click 10pt
        // below the bottom edge (y=110) at x=100 is displayed
        // (0.5, 1.1), out of range on the axis the viewer sees.
        //
        // The result stays in displayed space: rotating it into the
        // device's native frame is the daemon's job, and
        // `OrientationSurfaceCoordinatesTests` pins that half.
        let point = try #require(
            SimGestureMath.extendedNormalizedPoint(
                viewPoint: CGPoint(x: 100, y: 110),
                viewSize: CGSize(width: 200, height: 100),
                surfaceSize: CGSize(width: 100, height: 200),
                orientation: .landscapeLeft
            )
        )
        #expect(abs(point.x - 0.5) < 1e-9)
        #expect(abs(point.y - 1.1) < 1e-9)
    }
}

/// Input against a creased picture.
///
/// The renderer bends the picture and the user aims at what they see, so the
/// gesture path has to undo the bend. This is the half of the fold that is
/// invisible when it is wrong: the picture looks right and the taps land
/// short.
struct SimGestureMathCreaseTests {
    /// The Duo's inner panel, which is what the hinge runs through, shown at
    /// its own size so the letterbox is the identity and only the fold moves
    /// anything.
    private let surface = CGSize(width: 2_007, height: 2_853)
    private let view = CGSize(width: 2_853, height: 2_007)
    private let orientation = Orientation.landscapeLeft

    /// The fold as this view draws it. The picture fills the view, so there
    /// is no room for the outer edges to grow and the fit draws it smaller.
    private func shown(_ crease: FoldCreaseGeometry.Crease) -> FoldCreaseGeometry.Crease {
        let rect = CGRect(origin: .zero, size: view)
        return FoldCreaseGeometry.fitted(crease, picture: rect, margin: 0, within: rect, vertical: true)
    }

    /// Where the drawn leading outer edge sits, in view points.
    private func leadingEdge(_ crease: FoldCreaseGeometry.Crease) -> CGFloat {
        let fit = shown(crease)
        return view.width * (0.5 - CGFloat(fit.outerAcross * fit.scale) / 2)
    }

    private func normalized(
        x: CGFloat,
        crease: FoldCreaseGeometry.Crease?
    ) -> CGPoint? {
        SimGestureMath.normalizedPoint(
            viewPoint: CGPoint(x: x, y: view.height / 2),
            viewSize: view,
            surfaceSize: surface,
            orientation: orientation,
            displayInset: 0,
            crease: crease
        )
    }

    @Test
    func aTapOnTheBentEdgeReachesTheEdgeOfTheGuestScreen() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: FoldPosture.book.degrees))
        let edge = leadingEdge(crease)
        let bent = try #require(normalized(x: edge, crease: crease))
        #expect(abs(bent.x) < 1e-6)
        // The same click read flat lands well inside the guest's screen, which
        // is exactly the error the inverse exists to remove. `book` is a gentle
        // bend and still misses by several percent of the screen's width.
        let flat = try #require(normalized(x: edge, crease: nil))
        #expect(flat.x > 0.05)
    }

    @Test
    func theCentreIsUnmovedByTheFold() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: FoldPosture.book.degrees))
        let bent = try #require(normalized(x: view.width / 2, crease: crease))
        #expect(abs(bent.x - 0.5) < 1e-9)
    }

    @Test
    func aTapInTheAreaTheFoldVacatedIsNotOnTheScreen() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: FoldPosture.book.degrees))
        // Inside the pane's picture rect, outside the bent picture.
        let vacated = leadingEdge(crease) / 2
        #expect(normalized(x: vacated, crease: crease) == nil)
        // Without the fold that same point is ordinary screen.
        #expect(normalized(x: vacated, crease: nil) != nil)
    }

    /// With room to grow, the outer edges reach past the flat picture, and a
    /// tap there is on the guest's screen even though the flat rect never
    /// covered it.
    @Test
    func aTapOnTheEdgeGrownPastTheFlatRectLands() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: FoldPosture.book.degrees))
        // Taller than the picture, so the letterbox leaves room above and
        // below it for the fold to grow into.
        let tall = CGSize(width: view.width, height: view.height + 400)
        let top = (tall.height - view.height) / 2
        let edgeX = view.width * (0.5 - CGFloat(crease.outerAcross) / 2)
        // Above the flat picture's top, but under the grown edge's top.
        let grownTop = tall.height / 2 - CGFloat(crease.outerAlong) * view.height / 2
        let y = (grownTop + top) / 2
        #expect(y < top)
        let point = SimGestureMath.normalizedPoint(
            viewPoint: CGPoint(x: edgeX + 4, y: y),
            viewSize: tall,
            surfaceSize: surface,
            orientation: orientation,
            displayInset: 0,
            crease: crease
        )
        #expect(point != nil)
    }

    @Test
    func anEdgeSwipeKeepsItsOffScreenCoordinates() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: FoldPosture.book.degrees))
        // Below the picture, where the App Switcher swipe starts. The extended
        // path must keep handing back out-of-range values rather than dropping
        // the point, because the cross-edge trajectory is made of them.
        let extended = SimGestureMath.extendedNormalizedPoint(
            viewPoint: CGPoint(x: view.width / 2, y: view.height * 1.05),
            viewSize: view,
            surfaceSize: surface,
            orientation: orientation,
            displayInset: 0,
            crease: crease
        )
        let point = try #require(extended)
        #expect(point.y > 1)
    }
}

/// The two gesture entry points disagree about containment on purpose.
struct SimGestureMathCreaseBoundsTests {
    private let surface = CGSize(width: 2_007, height: 2_853)
    private let view = CGSize(width: 2_853, height: 2_007)

    /// Halfway between the view's edge and the drawn leading outer edge: inside
    /// the flat picture, outside the bent one.
    private func vacatedX(_ crease: FoldCreaseGeometry.Crease) -> CGFloat {
        let rect = CGRect(origin: .zero, size: view)
        let fit = FoldCreaseGeometry.fitted(crease, picture: rect, margin: 0, within: rect, vertical: true)
        return view.width * (0.5 - CGFloat(fit.outerAcross * fit.scale) / 2) / 2
    }

    @Test
    func theStrictPathRejectsWhatTheFoldTurnedAwayFrom() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: FoldPosture.book.degrees))
        let vacated = vacatedX(crease)
        #expect(
            SimGestureMath.normalizedPoint(
                viewPoint: CGPoint(x: vacated, y: view.height / 2),
                viewSize: view,
                surfaceSize: surface,
                orientation: .landscapeLeft,
                displayInset: 0,
                crease: crease
            ) == nil
        )
    }

    @Test
    func theExtendedPathCarriesThatSamePointOffScreen() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: FoldPosture.book.degrees))
        let vacated = vacatedX(crease)
        let point = try #require(
            SimGestureMath.extendedNormalizedPoint(
                viewPoint: CGPoint(x: vacated, y: view.height / 2),
                viewSize: view,
                surfaceSize: surface,
                orientation: .landscapeLeft,
                displayInset: 0,
                crease: crease
            )
        )
        // Off the screen, and on the side it left by, so a drag crossing the
        // edge keeps its direction.
        #expect(point.x < 0)
    }
}
