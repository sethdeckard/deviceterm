// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol

/// How a foldable's picture bends at the hinge.
///
/// The panel that spans the hinge is two flat halves joined along the crease.
/// Bending it lays the outer edges in the screen plane and pushes the crease
/// away from the viewer, the way an open book sits with its spine at the back,
/// followed by a perspective projection: the halves stay rectangles in space
/// and become trapezoids on screen, pinched in at the crease.
///
/// Everything here is dimensionless, expressed as a fraction of the flat
/// picture's half-extents, so the renderer can scale it into normalized device
/// coordinates and the bezel into points and the two cannot disagree about
/// where the crease runs. Which axis it runs along is the caller's to supply,
/// and `creaseRunsVertically(in:)` answers that from the device's orientation.
enum FoldCreaseGeometry {
    /// A bent picture, as fractions of the flat one.
    struct Crease: Equatable {
        /// Where each half's outer edge sits, measured across the crease as a
        /// fraction of the flat half-extent. `1` is flat; smaller values are
        /// the half turning away.
        ///
        /// The outer edges stay in the screen plane, so this is the turn alone
        /// with no perspective in it.
        let outerAcross: Double
        /// The crease's half-extent along itself, as a fraction of the flat
        /// one. `1` is flat; smaller values are the perspective taper that
        /// makes the receding crease shorter than the outer edges, which is
        /// what reads as the picture folding away from the viewer rather than
        /// toward them.
        let creaseAlong: Double
        /// Brightness multiplier for the half on the low side of the across
        /// axis, which is the one turned toward the light.
        let leadingShade: Double
        /// Brightness multiplier for the half on the high side, turned away.
        let trailingShade: Double
        /// How far each half is turned off the screen plane, in radians.
        /// Kept because the projection has to be undone as well as applied:
        /// a click lands on the bent picture and the guest is owed the point
        /// that pixel came from.
        let turn: Double
    }

    /// A bent half's four corners, in the coordinate space of the rect it was
    /// built from. Ordered around the outline.
    struct HalfQuad: Equatable {
        let outerLow: CGPoint
        let outerHigh: CGPoint
        let creaseHigh: CGPoint
        let creaseLow: CGPoint
    }

    /// Angles at or above this read as flat.
    ///
    /// A hinge a degree short of straight produces a sub-pixel bend, and
    /// taking the flat path there keeps an unfolded pane on the same single
    /// quad every other device draws.
    static let flatDegrees: Double = 179

    /// How far the viewer sits from the picture, as a multiple of the flat
    /// picture's half-extent across the crease.
    ///
    /// Expressing the distance in those units is what makes the projection
    /// dimensionless: the perspective divide then depends on the hinge angle
    /// alone, so a pane of any size and aspect bends by the same fractions.
    /// Larger values flatten the effect toward an orthographic bend. Fitted to
    /// the taper Device Hub draws at the same hinge angles, so a pane and
    /// Device Hub sitting side by side bend by the same amount.
    private static let viewerDistance: Double = 6

    /// How far the light sits off the screen normal, toward the leading half.
    ///
    /// This is the whole reason a crease reads as a fold rather than as a
    /// trapezoid: the two halves turn away from the viewer by the same angle,
    /// so nothing but their brightness distinguishes them.
    private static let lightAngle: Double = 20 * .pi / 180

    /// How dark the half turned furthest from the light is allowed to go.
    /// Short of black, so a steeply folded panel still shows its picture.
    private static let minimumShade: Double = 0.35

    /// The crease at `degrees`, or nil when the hinge is straight enough that
    /// the picture is flat and the caller should draw it whole.
    ///
    /// Nil for an out-of-range angle too: a reading no device could produce is
    /// not evidence of a bend.
    static func crease(degrees: Double) -> Crease? {
        guard FoldPosture.degreeRange.contains(degrees), degrees < flatDegrees else {
            return nil
        }
        // Each half turns by half the shortfall from straight, so the two meet
        // at the hinge angle and the picture stays symmetric about the crease.
        let turn = ((180 - degrees) / 2) * .pi / 180
        // The perspective divide, from the crease's depth behind the outer
        // edges.
        let foreshortening = viewerDistance / (viewerDistance + sin(turn))
        return Crease(
            outerAcross: cos(turn),
            creaseAlong: foreshortening,
            leadingShade: shade(turnedBy: -turn),
            trailingShade: shade(turnedBy: turn),
            turn: turn
        )
    }

    /// Where a flat point lands once the panel bends.
    ///
    /// `screen` is the picture's flat rect, which is the fold's frame of
    /// reference: the crease runs down its middle and its own edges are the
    /// ones that stay in the screen plane. `point` may sit outside it. The
    /// bezel does, and it is on the same rigid half, so it keeps going on that
    /// half's plane and comes *toward* the viewer past the screen's edge.
    ///
    /// Projecting the bezel through the screen's frame rather than its own is
    /// what keeps the two aligned. Bending a larger rect by the same fractions
    /// insets it by proportionally more, which closes the gap between frame
    /// and picture at the outer edges while leaving it open at the crease.
    static func projected(
        _ point: CGPoint,
        in screen: CGRect,
        crease: Crease,
        vertical: Bool
    ) -> CGPoint {
        let centre = CGPoint(x: screen.midX, y: screen.midY)
        let acrossHalf = (vertical ? screen.width : screen.height) / 2
        guard acrossHalf > 0 else { return point }
        let acrossOffset = vertical ? point.x - centre.x : point.y - centre.y
        let alongOffset = vertical ? point.y - centre.y : point.x - centre.x
        // Depth behind the plane the outer edges lie in: deepest at the crease,
        // zero at the screen's edge, and negative past it.
        let depth = sin(crease.turn) * (1 - abs(acrossOffset / acrossHalf))
        let divisor = viewerDistance + depth
        guard divisor > 0 else { return point }
        let scale = viewerDistance / divisor
        let across = acrossOffset * cos(crease.turn) * scale
        let along = alongOffset * scale
        return vertical
            ? CGPoint(x: centre.x + across, y: centre.y + along)
            : CGPoint(x: centre.x + along, y: centre.y + across)
    }

    /// Where `rect` goes when the panel bends: one quad per half.
    ///
    /// `screen` is the picture's flat rect, the fold's frame of reference.
    /// Passing `rect` itself describes the picture; passing the bezel's rect
    /// describes the frame around it, bent by the same fold.
    static func halves(
        of rect: CGRect,
        foldedAbout screen: CGRect,
        crease: Crease,
        vertical: Bool
    ) -> (leading: HalfQuad, trailing: HalfQuad) {
        /// Build a flat corner from absolute across/along coordinates, then
        /// bend it.
        func corner(across: CGFloat, along: CGFloat) -> CGPoint {
            let flat = vertical
                ? CGPoint(x: across, y: along)
                : CGPoint(x: along, y: across)
            return projected(flat, in: screen, crease: crease, vertical: vertical)
        }

        let acrossLow = vertical ? rect.minX : rect.minY
        let acrossHigh = vertical ? rect.maxX : rect.maxY
        let acrossMid = vertical ? screen.midX : screen.midY
        let alongLow = vertical ? rect.minY : rect.minX
        let alongHigh = vertical ? rect.maxY : rect.maxX

        func half(outer: CGFloat) -> HalfQuad {
            HalfQuad(
                outerLow: corner(across: outer, along: alongLow),
                outerHigh: corner(across: outer, along: alongHigh),
                creaseHigh: corner(across: acrossMid, along: alongHigh),
                creaseLow: corner(across: acrossMid, along: alongLow)
            )
        }

        return (leading: half(outer: acrossLow), trailing: half(outer: acrossHigh))
    }

    /// Undo the bend: map a point on the creased picture back to where it sits
    /// on the flat one.
    ///
    /// Both are in displayed unit coordinates, `0...1` across the flat
    /// picture's rect.
    ///
    /// **Deliberately unbounded.** A point past the picture's edge maps past
    /// `0...1`, continuing on the same half's plane, because the off-screen
    /// path depends on those coordinates staying continuous as a drag crosses
    /// the edge: the system edge-gesture band keys on a value just over `1`.
    /// Clamping here, or rejecting, would step the coordinate backwards at the
    /// crease exactly where a swipe-up begins. Callers that need containment
    /// test it themselves.
    ///
    /// Nil only where the projection has no inverse, past the vanishing point
    /// of the bent half.
    ///
    /// Input has to make this trip because the rendered picture is what the
    /// user aimed at. Without it a tap near a bent edge reaches the guest
    /// short of where it landed, by exactly the foreshortening.
    static func flattened(
        unitPoint: CGPoint,
        crease: Crease,
        vertical: Bool
    ) -> CGPoint? {
        // Recast as signed fractions of the half-extents, which is the space
        // the projection was derived in.
        let across = ((vertical ? unitPoint.x : unitPoint.y) - 0.5) * 2
        let along = ((vertical ? unitPoint.y : unitPoint.x) - 0.5) * 2
        let turn = crease.turn
        // Inverting the projection for the flat across-fraction `u`, measured
        // from the crease out. A point at `u` sits at depth `sin(turn)·(1 - u)`
        // behind the outer edges, so both the scale and the position depend on
        // it and the two have to be solved together.
        let magnitude = abs(across)
        let denominator = viewerDistance * cos(turn) + magnitude * sin(turn)
        guard denominator > 0 else { return nil }
        let unsigned = magnitude * (viewerDistance + sin(turn)) / denominator
        let flatAcross = across < 0 ? -unsigned : unsigned
        // The along axis is foreshortened by the depth at *this* point across,
        // which is the crease's at the crease and none at all at the edge.
        let depth = viewerDistance + sin(turn) * (1 - unsigned)
        guard depth > 0 else { return nil }
        let flatAlong = along * depth / viewerDistance
        return vertical
            ? CGPoint(x: flatAcross / 2 + 0.5, y: flatAlong / 2 + 0.5)
            : CGPoint(x: flatAlong / 2 + 0.5, y: flatAcross / 2 + 0.5)
    }

    /// Lambert shading for a half turned `turn` off the screen plane,
    /// normalized so a flat picture is unshaded.
    private static func shade(turnedBy turn: Double) -> Double {
        let lit = cos(turn + lightAngle) / cos(lightAngle)
        return min(1, max(minimumShade, lit))
    }

    /// Whether the crease runs down the displayed picture rather than across
    /// it, for a device presenting `orientation`.
    ///
    /// The hinge divides the panel along its framebuffer's height, so the
    /// crease is a horizontal line in the texture. Displaying a landscape
    /// device turns that texture a quarter turn, which stands the crease up.
    static func creaseRunsVertically(in orientation: Orientation) -> Bool {
        orientation == .landscapeLeft || orientation == .landscapeRight
    }
}
