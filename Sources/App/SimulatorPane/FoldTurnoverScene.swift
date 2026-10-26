// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol
import Foundation

/// What to draw for one frame of a foldable turning over: each half's frame
/// and picture, posed, in the order the renderer paints them.
///
/// Pure, so the shape of a turnover can be checked without Metal. Lengths are
/// drawable pixels, in the crease's own axes: *across* it and *along* it, as
/// `FoldCreaseGeometry` has them, mapped onto the screen only when a vertex is
/// produced.
struct FoldTurnoverScene {
    /// One panel's measurements, in the crease's axes.
    ///
    /// For the inner panel these describe one half: `width` runs from the
    /// crease to the outer edge. For the cover they describe the whole cover,
    /// whose hinge edge sits at the crease once the device is shut.
    struct Panel: Equatable {
        /// The picture's extent across the crease.
        var width: Double
        /// Half the picture's extent along the crease.
        var halfHeight: Double
        /// The frame's width outside the picture, on the hinge side, on the
        /// outer side, and along the crease.
        var hingeInset: Double
        var outerInset: Double
        var alongInset: Double
        /// Corner radii of the picture and of the frame, on the hinge side
        /// and on the outer side.
        var screenHingeRadius: Double
        var screenOuterRadius: Double
        var bodyHingeRadius: Double
        var bodyOuterRadius: Double
    }

    /// What a quad is filled with.
    enum Fill: Equatable {
        case frame
        case innerPicture
        case coverPicture
    }

    /// One posed corner. `position` is in normalized device coordinates with y
    /// up; `divisor` the clip divisor; `unit` where the corner sits in its flat
    /// picture, `-1...1` with y up, before the texture's orientation turns it;
    /// `local` where it sits in its quad, centred, as `(across, along)`.
    struct Vertex: Equatable {
        let position: SIMD2<Float>
        let divisor: Float
        let unit: SIMD2<Float>
        let local: SIMD2<Float>
    }

    /// A rectangle on one half, posed. `vertices` go hinge-low, hinge-high,
    /// outer-high, outer-low. `halfSize` is its flat `(across, along)`
    /// half-extent, and the radii round its hinge and outer corners.
    struct Quad: Equatable {
        let vertices: [Vertex]
        let halfSize: SIMD2<Float>
        let hingeRadius: Float
        let outerRadius: Float
        let fill: Fill
    }

    /// A quad's corner before it's centred and fitted, in pixels around the
    /// crease.
    private struct PosedCorner {
        let across: Double
        let along: Double
        let divisor: Double
        let unit: SIMD2<Float>
        let local: SIMD2<Float>
    }

    /// Every quad posed, with the centring and fit that place them.
    private struct Placement {
        let posed: [Posed]
        let offset: Double
        let fit: Double
    }

    /// A quad before it's centred and fitted.
    private struct Posed {
        let corners: [PosedCorner]
        let halfSize: SIMD2<Float>
        let hingeRadius: Float
        let outerRadius: Float
        let fill: Fill
    }

    var inner: Panel
    var cover: Panel
    /// Whether the crease runs down the screen.
    var vertical: Bool
    /// The side of the crease the fixed half lies on, `±1`.
    var fixedSide: Double
    var pose: FoldPose
    /// The drawable's size.
    var drawable: CGSize
    /// The fold's fit. Lowered further for a pose that would otherwise run
    /// off the drawable.
    var scale: Double

    /// One frame of a turnover, measured against a drawable: both panels'
    /// pictures as the pane draws them at rest, their frames, the pose for
    /// `elapsed` seconds in, and the fit. `closedHinge` is the hinge's angle,
    /// in radians, that the closed end leans by (`FoldPose.closed(hinge:)`).
    /// Nil when a size isn't usable.
    ///
    /// Both pictures are fitted to the inner panel as it's displayed, so the
    /// cover comes out at the inner panel's pixel scale whichever way each is
    /// turned, as the steady drawing has it.
    static func measuring(
        innerSize: CGSize,
        coverSize: CGSize,
        innerOrientation: Orientation,
        coverOrientation: Orientation,
        family: DeviceFamily,
        drawable: CGSize,
        backing: CGFloat,
        insetPoints: CGFloat,
        direction: FoldTurnover.Direction,
        elapsed: Double,
        openTurn: Double,
        closedHinge: Double = 0
    ) -> FoldTurnoverScene? {
        let insetPx = insetPoints * backing
        guard let innerRect = SimGestureMath.imageRect(
            viewSize: drawable,
            surfaceSize: innerSize,
            orientation: innerOrientation,
            displayInset: insetPx,
            referenceSize: innerSize
        ),
            let coverRect = SimGestureMath.imageRect(
                viewSize: drawable,
                surfaceSize: coverSize,
                orientation: coverOrientation,
                displayInset: insetPx,
                referenceSize: SimGestureMath.reference(
                    innerSize,
                    displayedIn: innerOrientation,
                    forPictureIn: coverOrientation
                )
            ),
            let innerLayout = DeviceBezelLayoutMath.layout(
                family: family,
                imageRect: points(innerRect, backing: backing),
                panel: .foldableInner,
                orientation: innerOrientation
            ),
            let coverLayout = DeviceBezelLayoutMath.layout(
                family: family,
                imageRect: points(coverRect, backing: backing),
                panel: .foldableCover,
                orientation: coverOrientation
            )
        else { return nil }
        let vertical = FoldCreaseGeometry.creaseRunsVertically(in: innerOrientation)
        // From the open fold's fit to the cover's resting one over the motion,
        // so each end matches the steady drawing beside it.
        let openDegrees = 180 - 2 * openTurn * 180 / .pi
        let openScale = FoldCreaseGeometry.crease(degrees: openDegrees).map {
            FoldCreaseGeometry.fitted(
                $0,
                picture: innerRect,
                margin: insetPx,
                within: CGRect(origin: .zero, size: drawable),
                vertical: vertical
            ).scale
        } ?? 1
        return FoldTurnoverScene(
            inner: panel(innerLayout, picture: innerRect, vertical: vertical, backing: backing, halved: true),
            cover: panel(coverLayout, picture: coverRect, vertical: vertical, backing: backing, halved: false),
            vertical: vertical,
            fixedSide: FoldPose.fixedSide(innerDrawnIn: innerOrientation),
            pose: FoldTurnover.pose(
                direction: direction,
                elapsed: elapsed,
                openTurn: openTurn,
                closedHinge: closedHinge
            ),
            drawable: drawable,
            scale: FoldTurnover.scale(openScale: openScale, direction: direction, elapsed: elapsed)
        )
    }

    private static func points(_ rect: CGRect, backing: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX / backing,
            y: rect.minY / backing,
            width: rect.width / backing,
            height: rect.height / backing
        )
    }

    /// A panel's measurements in the crease's axes, in drawable pixels, from
    /// its laid-out frame. `halved` takes half the extent across the crease,
    /// which is what one of the inner panel's halves spans.
    ///
    /// The cover's frame is thickest at its spine and roundest away from it,
    /// so whichever side measures thicker is the hinge side, and the smaller
    /// radius goes there. The inner panel's frame is the same on both sides.
    private static func panel(
        _ layout: DeviceBezelLayout,
        picture: CGRect,
        vertical: Bool,
        backing: CGFloat,
        halved: Bool
    ) -> FoldTurnoverScene.Panel {
        let image = points(picture, backing: backing)
        let frame = layout.bezelRect
        let low = vertical ? image.minX - frame.minX : image.minY - frame.minY
        let high = vertical ? frame.maxX - image.maxX : frame.maxY - image.maxY
        let alongLow = vertical ? image.minY - frame.minY : image.minX - frame.minX
        let alongHigh = vertical ? frame.maxY - image.maxY : frame.maxX - image.maxX
        let screen = layout.screenCornerRadii
        let body = layout.cornerRadii
        let screenRadii = [screen.topLeft, screen.topRight, screen.bottomLeft, screen.bottomRight]
        let bodyRadii = [body.topLeft, body.topRight, body.bottomLeft, body.bottomRight]
        let across = (vertical ? picture.width : picture.height) / (halved ? 2 : 1)
        let alongExtent = vertical ? picture.height : picture.width
        let scale = Double(backing)
        return FoldTurnoverScene.Panel(
            width: Double(across),
            halfHeight: Double(alongExtent / 2),
            hingeInset: halved ? 0 : Double(max(low, high)) * scale,
            outerInset: Double(halved ? max(low, high) : min(low, high)) * scale,
            alongInset: Double((alongLow + alongHigh) / 2) * scale,
            screenHingeRadius: halved ? 0 : Double(screenRadii.min() ?? 0) * scale,
            screenOuterRadius: Double(screenRadii.max() ?? 0) * scale,
            bodyHingeRadius: halved ? 0 : Double(bodyRadii.min() ?? 0) * scale,
            bodyOuterRadius: Double(bodyRadii.max() ?? 0) * scale
        )
    }

    /// Everything to draw, in painter's order: the fixed half, then the
    /// swinging half, which is nearer the viewer wherever the two overlap.
    /// The swinging half shows the inner picture until it passes edge-on, and
    /// the cover after.
    ///
    /// The device stays centred on what's showing, as Device Hub keeps it,
    /// rather than sliding to one side with the swinging half: centred on the
    /// pictures' extent while the device is open, and settling onto the cover
    /// picture as the swing closes, which is where the cover rests.
    func quads() -> [Quad] {
        let placement = placed()
        let offset = placement.offset
        let fit = placement.fit
        return placement.posed.map { quad in
            Quad(
                vertices: quad.corners.map { corner in
                    let across = (corner.across + offset) * fit
                    let along = corner.along * fit
                    let screen = vertical ? CGPoint(x: across, y: along) : CGPoint(x: along, y: across)
                    return Vertex(
                        position: SIMD2(
                            Float(screen.x / (drawable.width / 2)),
                            Float(screen.y / (drawable.height / 2))
                        ),
                        divisor: Float(corner.divisor),
                        unit: corner.unit,
                        local: corner.local
                    )
                },
                halfSize: quad.halfSize,
                hingeRadius: quad.hingeRadius,
                outerRadius: quad.outerRadius,
                fill: quad.fill
            )
        }
    }

    /// Where a point in normalized device coordinates (y up) lands on the
    /// cover, as the cover is displayed: `(0, 0)` its top-left, the space
    /// `SimGestureMath.normalizedPoint` answers in. Nil when the cover isn't
    /// showing or the point is off it.
    ///
    /// The drawing run backwards: the fit and centring undone, then the
    /// swinging half's perspective, then the cover's place on that half.
    func coverPoint(ndc: SIMD2<Double>) -> CGPoint? {
        guard pose.showsCover else { return nil }
        let placement = placed()
        let offset = placement.offset
        let fit = placement.fit
        guard fit > 0 else { return nil }
        let screen = (x: ndc.x * Double(drawable.width) / 2, y: ndc.y * Double(drawable.height) / 2)
        let across = (vertical ? screen.x : screen.y) / fit - offset
        let along = (vertical ? screen.y : screen.x) / fit
        // `FoldPose.project` solved for the flat distance from the crease: a
        // projected `across` of side·d·cos t·V / (V − d·sin t) gives
        // d = across·V / (side·cos t·V + across·sin t), in half-extents.
        let viewer = FoldCreaseGeometry.viewerDistance
        let side = -fixedSide
        let turn = pose.swingTurn
        let projected = across / inner.width
        let denominator = side * cos(turn) * viewer + projected * sin(turn)
        guard abs(denominator) > 1e-9 else { return nil }
        let distanceUnits = projected * viewer / denominator
        let flatAlong = along * (viewer - distanceUnits * sin(turn)) / viewer
        let distance = distanceUnits * inner.width
        let middle = cover.hingeInset + cover.width / 2
        let flat = SIMD2(fixedSide * (distance - middle) / (cover.width / 2), flatAlong / cover.halfHeight)
        let unit = vertical ? flat : SIMD2(flat.y, flat.x)
        let point = CGPoint(x: (unit.x + 1) / 2, y: (1 - unit.y) / 2)
        guard (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        return point
    }

    private func placed() -> Placement {
        let swingSide = -fixedSide
        var posed = innerHalf(side: fixedSide, turn: pose.fixedTurn)
        if pose.showsCover {
            posed += coverFace(side: swingSide, turn: pose.swingTurn)
        } else {
            posed += innerHalf(side: swingSide, turn: pose.swingTurn)
        }
        let offset = centringOffset(posed)
        return Placement(posed: posed, offset: offset, fit: fitScale(posed, offset: offset))
    }

    /// How far across to move everything so what's showing is centred.
    private func centringOffset(_ posed: [Posed]) -> Double {
        let pictures = posed.filter { $0.fill != .frame }
        let acrosses = pictures.flatMap { $0.corners.map(\.across) }
        guard let low = acrosses.min(), let high = acrosses.max() else { return 0 }
        let extent = -(low + high) / 2
        guard pose.showsCover,
            let cover = pictures.first(where: { $0.fill == .coverPicture }) else { return extent }
        // Past edge-on, ease from the pictures' extent onto the cover alone, so
        // the last frame centres the cover exactly as it's drawn at rest.
        let coverAcrosses = cover.corners.map(\.across)
        let coverCentre = -((coverAcrosses.min() ?? 0) + (coverAcrosses.max() ?? 0)) / 2
        let settle = min(max((pose.swingTurn - .pi / 2) / (.pi / 2), 0), 1)
        return extent + (coverCentre - extent) * settle
    }

    /// The scale to draw at: `scale`, lowered just enough that every quad,
    /// frames included, stays on the drawable once centred.
    private func fitScale(_ posed: [Posed], offset: Double) -> Double {
        let halfAcross = Double(vertical ? drawable.width : drawable.height) / 2
        let halfAlong = Double(vertical ? drawable.height : drawable.width) / 2
        var reachAcross = 0.0
        var reachAlong = 0.0
        for corner in posed.flatMap(\.corners) {
            reachAcross = max(reachAcross, abs(corner.across + offset))
            reachAlong = max(reachAlong, abs(corner.along))
        }
        var fit = scale
        if reachAcross > 0 { fit = min(fit, halfAcross / reachAcross) }
        if reachAlong > 0 { fit = min(fit, halfAlong / reachAlong) }
        return fit
    }

    /// One half of the inner panel, front out: its frame, then its picture.
    private func innerHalf(side: Double, turn: Double) -> [Posed] {
        let frame = posedQuad(
            across: 0...(inner.width + inner.outerInset),
            halfAlong: inner.halfHeight + inner.alongInset,
            side: side,
            turn: turn,
            radii: (0, inner.bodyOuterRadius),
            fill: .frame
        ) { _, _ in .zero }
        let picture = posedQuad(
            across: 0...inner.width,
            halfAlong: inner.halfHeight,
            side: side,
            turn: turn,
            radii: (0, inner.screenOuterRadius),
            fill: .innerPicture
        ) { distance, along in
            // The flat inner picture, centred on the crease.
            SIMD2(Float(side * distance / inner.width), Float(along / inner.halfHeight))
        }
        return [frame, picture]
    }

    /// The back of the swinging half: the cover's frame, then the cover.
    ///
    /// Its texture coordinates are where each point lands on the flat cover
    /// once the device is shut, so the turnover's last frame is the cover as
    /// the pane draws it at rest.
    private func coverFace(side: Double, turn: Double) -> [Posed] {
        let frame = posedQuad(
            across: 0...(cover.hingeInset + cover.width + cover.outerInset),
            halfAlong: cover.halfHeight + cover.alongInset,
            side: side,
            turn: turn,
            radii: (cover.bodyHingeRadius, cover.bodyOuterRadius),
            fill: .frame
        ) { _, _ in .zero }
        let middle = cover.hingeInset + cover.width / 2
        let picture = posedQuad(
            across: cover.hingeInset...(cover.hingeInset + cover.width),
            halfAlong: cover.halfHeight,
            side: side,
            turn: turn,
            radii: (cover.screenHingeRadius, cover.screenOuterRadius),
            fill: .coverPicture
        ) { distance, along in
            SIMD2(
                Float(fixedSide * (distance - middle) / (cover.width / 2)),
                Float(along / cover.halfHeight)
            )
        }
        return [frame, picture]
    }

    /// A rectangle `across` the crease (distances from it, outward on its
    /// half) and `halfAlong` either way along it, posed on the half at
    /// `side` turned by `turn`. `unit` gives a corner's flat picture
    /// coordinate in `(across, along)`.
    private func posedQuad(
        across: ClosedRange<Double>,
        halfAlong: Double,
        side: Double,
        turn: Double,
        radii: (hinge: Double, outer: Double),
        fill: Fill,
        unit: (Double, Double) -> SIMD2<Float>
    ) -> Posed {
        let middle = (across.lowerBound + across.upperBound) / 2
        let corners: [(Double, Double)] = [
            (across.lowerBound, -halfAlong),
            (across.lowerBound, halfAlong),
            (across.upperBound, halfAlong),
            (across.upperBound, -halfAlong)
        ]
        return Posed(
            corners: corners.map { distance, along in
                let point = FoldPose.project(
                    distance: distance / inner.width,
                    along: along,
                    side: side,
                    turn: turn
                )
                let flat = unit(distance, along)
                return PosedCorner(
                    across: point.across * inner.width,
                    along: point.along,
                    divisor: point.divisor,
                    unit: vertical ? flat : SIMD2(flat.y, flat.x),
                    local: SIMD2(Float(distance - middle), Float(along))
                )
            },
            halfSize: SIMD2(Float((across.upperBound - across.lowerBound) / 2), Float(halfAlong)),
            hingeRadius: Float(radii.hinge),
            outerRadius: Float(radii.outer),
            fill: fill
        )
    }
}
