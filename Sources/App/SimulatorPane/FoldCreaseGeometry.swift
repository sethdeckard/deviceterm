// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol

/// How a foldable's picture bends at the hinge.
///
/// The panel that spans the hinge is two flat halves joined along the crease.
/// Bending it keeps the crease in the screen plane and swings the outer edges
/// toward the viewer, the way an open book sits with its spine at the back,
/// followed by a perspective projection: the halves stay rectangles in space
/// and become trapezoids on screen, taller at the outer edges than at the
/// crease. That is Device Hub's camera, measured off its window at three hinge
/// angles: the crease keeps its flat height and the outer edges grow, so a
/// folded device draws larger than a flat one.
///
/// Nothing is shaded. Device Hub leaves both halves at their flat brightness
/// at every angle, and the perspective alone reads as the fold.
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
        /// fraction of the flat half-extent, before `scale`. `1` is flat.
        ///
        /// The turn draws the edge inward and the perspective pushes it back
        /// out, because the edge has come toward the viewer.
        let outerAcross: Double
        /// The outer edges' half-extent along the crease, as a fraction of the
        /// flat one, before `scale`. Above `1` because the edges are nearer
        /// the viewer than the crease is. The crease itself stays at `1`.
        let outerAlong: Double
        /// How far each half is turned off the screen plane, in radians.
        /// Kept because the projection has to be undone as well as applied:
        /// a click lands on the bent picture and the guest is owed the point
        /// that pixel came from.
        let turn: Double
        /// Uniform scale the whole bent picture is drawn at, about the flat
        /// picture's centre.
        ///
        /// `1` is Device Hub's size. `fitted` lowers it when the grown edges
        /// would otherwise run past the view, so a fold never clips.
        var scale: Double = 1
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

    /// How far the viewer sits from the crease, as a multiple of the flat
    /// picture's half-extent across it.
    ///
    /// Expressing the distance in those units is what makes the projection
    /// dimensionless: the perspective divide then depends on the hinge angle
    /// alone, so a pane of any size and aspect bends by the same fractions.
    /// Larger values flatten the effect toward an orthographic bend. Fitted to
    /// what Device Hub draws, so a pane and Device Hub sitting side by side
    /// bend by the same amount.
    private static let viewerDistance: Double = 9.6

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
        // The perspective divide at the outer edges, which sit in front of
        // the crease by the turn.
        let growth = viewerDistance / (viewerDistance - sin(turn))
        return Crease(
            outerAcross: cos(turn) * growth,
            outerAlong: growth,
            turn: turn
        )
    }

    /// Recomputes `crease.scale` as the largest value from 0 through 1 that
    /// fits the bent picture and its bezel margin inside `bounds`.
    ///
    /// `picture` is the flat picture's rect, the fold's frame of reference.
    /// `margin` is the frame reserved around it on every side, which is what
    /// keeps the bent bezel in view as well as the picture. Never raises the
    /// scale past `1`: a pane with room to spare draws Device Hub's size, and
    /// only a pane without it draws smaller.
    ///
    /// Everything that draws or reads the bent picture has to call this with
    /// the same inputs, or the picture, its frame, and the point a click
    /// lands on disagree.
    static func fitted(
        _ crease: Crease,
        picture: CGRect,
        margin: CGFloat,
        within bounds: CGRect,
        vertical: Bool
    ) -> Crease {
        var unscaled = crease
        unscaled.scale = 1
        let frame = picture.insetBy(dx: -margin, dy: -margin)
        let bent = halves(of: frame, foldedAbout: picture, crease: unscaled, vertical: vertical)
        let corners = [bent.leading, bent.trailing].flatMap {
            [$0.outerLow, $0.outerHigh, $0.creaseHigh, $0.creaseLow]
        }
        let centre = CGPoint(x: picture.midX, y: picture.midY)
        // The largest scale about the centre that keeps every corner short of
        // the bound on its side.
        var scale = 1.0
        for corner in corners {
            let offsetX = corner.x - centre.x
            let offsetY = corner.y - centre.y
            if offsetX > 0 { scale = min(scale, Double((bounds.maxX - centre.x) / offsetX)) }
            if offsetX < 0 { scale = min(scale, Double((bounds.minX - centre.x) / offsetX)) }
            if offsetY > 0 { scale = min(scale, Double((bounds.maxY - centre.y) / offsetY)) }
            if offsetY < 0 { scale = min(scale, Double((bounds.minY - centre.y) / offsetY)) }
        }
        unscaled.scale = max(scale, 0)
        return unscaled
    }

    /// Where a flat point lands once the panel bends.
    ///
    /// `screen` is the picture's flat rect, which is the fold's frame of
    /// reference: the crease runs down its middle and stays in the screen
    /// plane, and its own edges are where each half's turn is measured to.
    /// `point` may sit outside it. The bezel does, and it is on the same rigid
    /// half, so it keeps going on that half's plane and comes further toward
    /// the viewer past the screen's edge.
    ///
    /// Projecting the bezel through the screen's frame rather than its own is
    /// what keeps the two aligned. Bending a larger rect about its own centre
    /// would put the same place on the half at a different depth, and the
    /// frame would drift off what it frames.
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
        // Distance toward the viewer from the crease's plane: none at the
        // crease, the full turn at the screen's edge, and more past it.
        let forward = sin(crease.turn) * abs(acrossOffset / acrossHalf)
        let divisor = viewerDistance - forward
        guard divisor > 0 else { return point }
        let scale = viewerDistance / divisor * crease.scale
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
    /// away from where it landed, by exactly the perspective.
    static func flattened(
        unitPoint: CGPoint,
        crease: Crease,
        vertical: Bool
    ) -> CGPoint? {
        // Recast as signed fractions of the half-extents, which is the space
        // the projection was derived in, with the fit's scale taken back out.
        guard crease.scale > 0 else { return nil }
        let across = ((vertical ? unitPoint.x : unitPoint.y) - 0.5) * 2 / crease.scale
        let along = ((vertical ? unitPoint.y : unitPoint.x) - 0.5) * 2 / crease.scale
        let turn = crease.turn
        // Inverting the projection for the flat across-fraction `u`, measured
        // from the crease out. A point at `u` sits `sin(turn)·u` in front of
        // the crease, so both the scale and the position depend on it and the
        // two have to be solved together.
        let magnitude = abs(across)
        let denominator = viewerDistance * cos(turn) + magnitude * sin(turn)
        guard denominator > 0 else { return nil }
        let unsigned = magnitude * viewerDistance / denominator
        let flatAcross = across < 0 ? -unsigned : unsigned
        // The along axis is magnified by how far forward *this* point across
        // sits, which is nothing at the crease and the most at the edge.
        let divisor = viewerDistance - sin(turn) * unsigned
        guard divisor > 0 else { return nil }
        let flatAlong = along * divisor / viewerDistance
        return vertical
            ? CGPoint(x: flatAcross / 2 + 0.5, y: flatAlong / 2 + 0.5)
            : CGPoint(x: flatAlong / 2 + 0.5, y: flatAcross / 2 + 0.5)
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
