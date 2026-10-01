// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import CoreGraphics
import DaemonProtocol
import Testing

/// Pure-math pins for the per-family bezel
/// geometry the wrapper paints around the sim screen. Each family has
/// its own assertion shape:
///
///   - phone → bezel rect insetting `imageRect`, no crown.
///   - pad → thinner bezel rect, no crown.
///   - watch → bezel + crown rect on the trailing (right) edge.
///   - tv → layout is nil (no bezel painted; letterbox stays as-is).
///   - unknown → falls back to the phone style.
///
/// A foldable's two panels have their own geometry, measured off Apple's
/// `Bezel-iPhone-Duo` design resource rather than derived from a ratio, and
/// `FoldableBezelLayoutTests` pins those numbers: the frame's thickness on
/// each edge of the device and the rounding of each panel's display. Those
/// are the only numbers here that claim to describe a real device, so the
/// assertions scale the device-pixel measurements to the test panel's size
/// in points.
///
/// The thicknesses and radii scale with the smaller imageRect dimension and
/// are clamped to a reasonable range; these tests pin the boundary behavior
/// so a future scale tweak can't accidentally produce a 1pt-thick bezel or a
/// square-cornered phone.
struct DeviceBezelLayoutTests {
    private let screenRect = CGRect(x: 100, y: 50, width: 200, height: 400)

    @Test
    func phoneHasBezelAndNoCrown() throws {
        let layout = try #require(
            DeviceBezelLayoutMath.layout(family: .phone, imageRect: screenRect)
        )
        // Bezel insets outward from the image rect.
        #expect(layout.bezelRect.origin.x < screenRect.origin.x)
        #expect(layout.bezelRect.origin.y < screenRect.origin.y)
        #expect(layout.bezelRect.maxX > screenRect.maxX)
        #expect(layout.bezelRect.maxY > screenRect.maxY)
        #expect(layout.crownRect == nil)
        // A one-panel phone's frame is the same thickness all round, so its
        // screen stays centred in it.
        #expect(abs(layout.bezelRect.midX - screenRect.midX) < 1e-6)
        #expect(abs(layout.bezelRect.midY - screenRect.midY) < 1e-6)
    }

    @Test
    func padHasBezelButNoCrown() throws {
        let layout = try #require(
            DeviceBezelLayoutMath.layout(family: .pad, imageRect: screenRect)
        )
        #expect(layout.crownRect == nil)
        // Pad bezel is thinner than phone, asserted via comparison
        // on the same image rect.
        let phone = try #require(
            DeviceBezelLayoutMath.layout(family: .phone, imageRect: screenRect)
        )
        let phoneInset = screenRect.minX - phone.bezelRect.minX
        let padInset = screenRect.minX - layout.bezelRect.minX
        #expect(padInset < phoneInset)
    }

    @Test
    func watchHasBezelAndCrownOnRightEdge() throws {
        let layout = try #require(
            DeviceBezelLayoutMath.layout(family: .watch, imageRect: screenRect)
        )
        let crown = try #require(layout.crownRect)
        // Crown straddles the bezel's right edge, so midX matches
        // the bezel's max x.
        #expect(abs(crown.midX - layout.bezelRect.maxX) < 1e-6)
        // Vertically centered on the image rect.
        #expect(abs(crown.midY - screenRect.midY) < 1e-6)
        // Watch corner radius is large (squircle-ish), bigger
        // than phone's at the same screen size.
        let phone = try #require(
            DeviceBezelLayoutMath.layout(family: .phone, imageRect: screenRect)
        )
        #expect(layout.cornerRadii.widest > phone.cornerRadii.widest)
    }

    @Test
    func tvProducesNoBezelLayout() {
        #expect(
            DeviceBezelLayoutMath.layout(family: .tv, imageRect: screenRect) == nil
        )
    }

    /// A tv draws no frame whichever panel is asked for, so a caller that
    /// passed a foldable panel by mistake gets the letterbox, not a phone.
    @Test
    func tvProducesNoBezelLayoutForAnyPanel() {
        #expect(
            DeviceBezelLayoutMath.layout(
                family: .tv,
                imageRect: screenRect,
                panel: .foldableInner
            ) == nil
        )
    }

    @Test
    func unknownFallsBackToPhone() throws {
        let unknown = try #require(
            DeviceBezelLayoutMath.layout(family: .unknown, imageRect: screenRect)
        )
        let phone = try #require(
            DeviceBezelLayoutMath.layout(family: .phone, imageRect: screenRect)
        )
        #expect(unknown.bezelRect == phone.bezelRect)
        #expect(unknown.cornerRadii == phone.cornerRadii)
        #expect(unknown.screenCornerRadii == phone.screenCornerRadii)
    }

    @Test
    func degenerateImageRectReturnsNil() {
        #expect(
            DeviceBezelLayoutMath.layout(family: .phone, imageRect: .zero) == nil
        )
    }

    @Test
    func smallScreenClampsToMinimumBezel() throws {
        // 50×50 phone screen: scaled-by-ratio inset would be ~2pt;
        // the 8pt floor kicks in so the bezel is still readable.
        let tiny = CGRect(x: 0, y: 0, width: 50, height: 50)
        let layout = try #require(
            DeviceBezelLayoutMath.layout(family: .phone, imageRect: tiny)
        )
        let inset = tiny.minX - layout.bezelRect.minX
        #expect(inset >= 8)
    }

    @Test
    func largeScreenClampsToMaximumBezel() throws {
        // 2000×2000 phone screen: scaled-by-ratio inset would be
        // ~90pt; the 16pt ceiling clamps so a maxed-out pane doesn't
        // look like a picture frame.
        let huge = CGRect(x: 0, y: 0, width: 2_000, height: 2_000)
        let layout = try #require(
            DeviceBezelLayoutMath.layout(family: .phone, imageRect: huge)
        )
        let inset = huge.minX - layout.bezelRect.minX
        #expect(inset <= 16)
    }

    /// Every family's painted frame has to stay inside the reserve the
    /// aspect-fit held back for it, or the bezel layer is clipped against
    /// the pane's edge instead of sitting in it.
    @Test(arguments: [DeviceFamily.phone, .pad, .watch, .unknown])
    func paintedFrameStaysInsideTheReserve(family: DeviceFamily) throws {
        let reserve = DeviceBezelLayoutMath.maxBezelInset(family: family)
        for panel in [
            DeviceBezelLayoutMath.Panel.standard, .foldableCover, .foldableInner
        ] {
            for reference in [40.0, 200.0, 600.0, 4_000.0] as [CGFloat] {
                let image = CGRect(x: 0, y: 0, width: reference, height: reference * 1.5)
                let layout = try #require(
                    DeviceBezelLayoutMath.layout(
                        family: family,
                        imageRect: image,
                        panel: panel
                    )
                )
                let thickest = max(
                    image.minX - layout.bezelRect.minX,
                    layout.bezelRect.maxX - image.maxX,
                    image.minY - layout.bezelRect.minY,
                    layout.bezelRect.maxY - image.maxY
                )
                #expect(thickest <= reserve)
            }
        }
    }
}

/// Pins for the panel geometry measured off the alpha channel of
/// `Bezel-iPhone-Duo` in Apple Design Resources, whose body art is 1:1 with
/// device pixels. Every ratio below is a thickness in those pixels over the
/// panel's own shorter side. The layout reproduces these measurements within
/// the unclamped size range, and preserves their proportions when clamped.
///
/// The art is licensed and is not in this repo, so there is no fixture to
/// re-measure from; these numbers are the only thing derived from it.
///
/// Each panel is drawn at a size chosen so none of these land on the inset
/// range's floor or ceiling, because a clamped frame pins the clamp rather
/// than the measurement.
struct FoldableBezelLayoutTests {
    /// The cover panel's display, in device pixels.
    private let coverWidth: CGFloat = 1_398
    /// The inner panel's shorter side, in device pixels.
    private let innerShortSide: CGFloat = 2_007
    /// Shorter side each panel is drawn at, in points.
    private let coverReference: CGFloat = 300
    private let innerReference: CGFloat = 400

    private var coverRect: CGRect {
        CGRect(x: 10, y: 20, width: coverReference, height: coverReference * 2_034 / 1_398)
    }

    private var innerRect: CGRect {
        CGRect(x: 10, y: 20, width: innerReference * 2_853 / 2_007, height: innerReference)
    }

    /// The hinge spine runs down one side of the cover panel and is much
    /// thicker than the edge opposite it, which is the whole reason the
    /// frame needs four thicknesses rather than one.
    @Test
    func coverPanelFrameIsThickestOnTheSpine() throws {
        let layout = try #require(
            DeviceBezelLayoutMath.layout(
                family: .phone,
                imageRect: coverRect,
                panel: .foldableCover
            )
        )
        let frame = insets(of: layout, around: coverRect)
        #expect(abs(frame.left - 77 / coverWidth * coverReference) < 0.01)
        #expect(abs(frame.right - 48 / coverWidth * coverReference) < 0.01)
        #expect(abs(frame.top - 56 / coverWidth * coverReference) < 0.01)
        #expect(abs(frame.bottom - 47 / coverWidth * coverReference) < 0.01)
        #expect(frame.left > frame.right * 1.5)
    }

    /// Turning the device carries its thicker edge with it: the frame is
    /// the device's, not the pane's, so the spine cannot stay on the left
    /// while the picture rotates out from under it.
    @Test
    func rotatingTheCoverPanelCarriesTheSpineRound() throws {
        let portrait = try #require(
            DeviceBezelLayoutMath.layout(
                family: .phone,
                imageRect: coverRect,
                panel: .foldableCover,
                orientation: .portrait
            )
        )
        let landscape = try #require(
            DeviceBezelLayoutMath.layout(
                family: .phone,
                imageRect: coverRect,
                panel: .foldableCover,
                orientation: .landscapeLeft
            )
        )
        let upright = insets(of: portrait, around: coverRect)
        let turned = insets(of: landscape, around: coverRect)
        // Turned a quarter anticlockwise, the spine leaves the left edge
        // for the bottom one and the rest follow the same turn.
        #expect(abs(turned.bottom - upright.left) < 1e-6)
        #expect(abs(turned.left - upright.top) < 1e-6)
        #expect(abs(turned.right - upright.bottom) < 1e-6)
        #expect(abs(turned.top - upright.right) < 1e-6)
    }

    /// The inner panel sits symmetrically in the body, with the two ends of
    /// its long axis thicker than its sides.
    @Test
    func innerPanelFrameIsSymmetricAndThickerOnTheLongAxis() throws {
        let layout = try #require(
            DeviceBezelLayoutMath.layout(
                family: .phone,
                imageRect: innerRect,
                panel: .foldableInner,
                orientation: .landscapeLeft
            )
        )
        // Landscape, so the long axis runs across the screen and its ends
        // are the left and right edges.
        let frame = insets(of: layout, around: innerRect)
        let longEnd = 61 / innerShortSide * innerReference
        let shortEnd = 48 / innerShortSide * innerReference
        #expect(abs(frame.left - longEnd) < 0.01)
        #expect(abs(frame.right - longEnd) < 0.01)
        #expect(abs(frame.top - shortEnd) < 0.01)
        #expect(abs(frame.bottom - shortEnd) < 0.01)
    }

    /// The cover display is a D: the two corners against the hinge spine
    /// are nearly square and the two opposite them are heavily rounded. One
    /// radius for the panel can only be right at one end of that.
    @Test
    func theCoverDisplayIsADRatherThanARoundedRectangle() throws {
        let layout = try #require(
            DeviceBezelLayoutMath.layout(
                family: .phone,
                imageRect: coverRect,
                panel: .foldableCover
            )
        )
        let corners = layout.screenCornerRadii
        let spine = 26 / coverWidth * coverReference
        let outer = 177 / coverWidth * coverReference
        #expect(abs(corners.topLeft - spine) < 0.01)
        #expect(abs(corners.bottomLeft - spine) < 0.01)
        #expect(abs(corners.topRight - outer) < 0.01)
        #expect(abs(corners.bottomRight - outer) < 0.01)
        #expect(corners.topRight > corners.topLeft * 5)
    }

    /// Turning the device carries the flat end of the D with it, the same
    /// way it carries the thicker edge of the frame.
    @Test
    func rotatingTheCoverPanelCarriesTheFlatEndRound() throws {
        let landscape = try #require(
            DeviceBezelLayoutMath.layout(
                family: .phone,
                imageRect: coverRect,
                panel: .foldableCover,
                orientation: .landscapeLeft
            )
        )
        let corners = landscape.screenCornerRadii
        let spine = 26 / coverWidth * coverReference
        let outer = 177 / coverWidth * coverReference
        // Portrait's left edge becomes the bottom, so the square pair goes
        // with it and the round pair lands along the top.
        #expect(abs(corners.bottomLeft - spine) < 0.01)
        #expect(abs(corners.bottomRight - spine) < 0.01)
        #expect(abs(corners.topLeft - outer) < 0.01)
        #expect(abs(corners.topRight - outer) < 0.01)
    }

    /// The inner panel is a plain rounded rectangle, so all four of its
    /// corners match. Only the cover panel is a D.
    @Test
    func theInnerDisplayIsARoundedRectangle() throws {
        let layout = try #require(
            DeviceBezelLayoutMath.layout(
                family: .phone,
                imageRect: innerRect,
                panel: .foldableInner,
                orientation: .landscapeLeft
            )
        )
        let corners = layout.screenCornerRadii
        let expected = 168 / innerShortSide * innerReference
        #expect(abs(corners.topLeft - expected) < 0.01)
        #expect(abs(corners.topRight - expected) < 0.01)
        #expect(abs(corners.bottomLeft - expected) < 0.01)
        #expect(abs(corners.bottomRight - expected) < 0.01)
    }

    /// Each outer radius is the display's at that corner plus the thinner of
    /// the two frame edges meeting there, rather than a radius of its own.
    @Test
    func bodyRoundingFollowsTheDisplayPlusTheThinnestEdge() throws {
        let layout = try #require(
            DeviceBezelLayoutMath.layout(
                family: .phone,
                imageRect: coverRect,
                panel: .foldableCover
            )
        )
        let frame = insets(of: layout, around: coverRect)
        let screen = layout.screenCornerRadii
        let body = layout.cornerRadii
        #expect(abs(body.topLeft - (screen.topLeft + min(frame.left, frame.top))) < 1e-6)
        #expect(abs(body.topRight - (screen.topRight + min(frame.right, frame.top))) < 1e-6)
        #expect(abs(body.bottomLeft - (screen.bottomLeft + min(frame.left, frame.bottom))) < 1e-6)
        #expect(
            abs(body.bottomRight - (screen.bottomRight + min(frame.right, frame.bottom))) < 1e-6
        )
    }

    /// Clamping a frame into the points range it is drawn in scales all
    /// four edges together, so a pane too small to show the true proportion
    /// still shows the right shape.
    @Test
    func clampingKeepsTheProportionsBetweenEdges() throws {
        let tiny = CGRect(x: 0, y: 0, width: 60, height: 87)
        let layout = try #require(
            DeviceBezelLayoutMath.layout(
                family: .phone,
                imageRect: tiny,
                panel: .foldableCover
            )
        )
        let frame = insets(of: layout, around: tiny)
        #expect(frame.left >= 8)
        #expect(abs(frame.left / frame.right - 77 / 48) < 1e-6)
    }

    /// A foldable's cover panel is not an ordinary phone's display, and
    /// `spansHinge` alone cannot tell them apart: both are flat and
    /// neither spans the hinge.
    @Test
    func theCoverPanelIsNotTheStandardPhoneFrame() throws {
        let cover = try #require(
            DeviceBezelLayoutMath.layout(
                family: .phone,
                imageRect: coverRect,
                panel: .foldableCover
            )
        )
        let standard = try #require(
            DeviceBezelLayoutMath.layout(
                family: .phone,
                imageRect: coverRect,
                panel: .standard
            )
        )
        #expect(cover.bezelRect != standard.bezelRect)
        #expect(cover.screenCornerRadii.topLeft < standard.screenCornerRadii.topLeft)
    }

    /// How thick the painted frame came out on each displayed edge.
    private func insets(
        of layout: DeviceBezelLayout,
        around imageRect: CGRect
    ) -> DeviceBezelLayoutMath.Insets {
        DeviceBezelLayoutMath.Insets(
            left: imageRect.minX - layout.bezelRect.minX,
            right: layout.bezelRect.maxX - imageRect.maxX,
            top: imageRect.minY - layout.bezelRect.minY,
            bottom: layout.bezelRect.maxY - imageRect.maxY
        )
    }
}
