// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// A foldable posed as Device Hub draws it turning over: two rigid halves
/// hinged at the crease, each turned off the screen plane by its own amount.
///
/// Through a turnover both halves first yaw together until the fixed half
/// faces the viewer, then the swinging half closes over it. The swinging
/// half carries the cover on its back, so past a quarter turn the viewer
/// sees the cover, and at a half turn it lies on the fixed half with the
/// cover facing out: the closed device. The symmetric fold
/// `FoldCreaseGeometry` draws is the pose with both turns equal.
///
/// Dimensionless like `FoldCreaseGeometry`, in the same units and with the
/// same viewer distance: distances are fractions of the inner picture's flat
/// half-extent across the crease, so the two agree wherever they overlap.
struct FoldPose: Equatable {
    /// A projected point: where it lands across and along the crease, and
    /// the clip divisor that keeps its texture perspective-correct.
    struct Point: Equatable {
        let across: Double
        let along: Double
        let divisor: Double
    }

    /// The closed device, cover out: the swinging half lies on the fixed
    /// half.
    static let closed = FoldPose(fixedTurn: 0, swingTurn: .pi)
    /// How much of the hinge's angle the cover half leans by while the device
    /// is shown closed, fitted to Device Hub's frames: its closed device leans
    /// with the hinge and lies flat only at `0`.
    static let closedLeanShare = 0.41

    /// How far the fixed half is turned off the screen plane, in radians.
    /// `0` faces the viewer.
    var fixedTurn: Double
    /// How far the swinging half is turned, in radians. Past `π / 2` its back,
    /// the cover, faces the viewer; at `π` it lies on the fixed half.
    var swingTurn: Double

    /// Whether the swinging half shows its back, the cover, to the viewer.
    var showsCover: Bool { cos(swingTurn) < 0 }

    /// The device shown closed with its hinge at `hinge` radians: the cover
    /// half leans out toward the viewer by `closedLeanShare` of the angle, and
    /// the fixed half leans back behind it by the rest, so the two still meet
    /// at the hinge's angle. Flat, `closed`, at `0`.
    static func closed(hinge: Double) -> FoldPose {
        let angle = max(0, hinge)
        let lean = closedLeanShare * angle
        return FoldPose(fixedTurn: lean - angle, swingTurn: .pi - lean)
    }

    /// The open fold at `turn`, both halves alike.
    static func open(turn: Double) -> FoldPose {
        FoldPose(fixedTurn: turn, swingTurn: turn)
    }

    /// Where a point on a half lands.
    ///
    /// `distance` is how far out from the crease the point sits on its half,
    /// `along` how far along the crease, both in half-extents and both flat;
    /// `side` is the side of the crease the half lies on when flat, `±1`. A
    /// point past the picture's edge (the bezel) keeps going on the same rigid
    /// half, as `FoldCreaseGeometry.projected` has it.
    static func project(distance: Double, along: Double, side: Double, turn: Double) -> Point {
        let viewer = FoldCreaseGeometry.viewerDistance
        // Toward the viewer from the crease's plane, which is what the
        // perspective divide reads.
        let forward = distance * sin(turn)
        let divisor = viewer - forward
        let magnification = viewer / divisor
        return Point(
            across: side * distance * cos(turn) * magnification,
            along: along * magnification,
            divisor: divisor / viewer
        )
    }

    /// The side of the crease, `±1` in the crease's across axis, that the
    /// fixed half lies on in an inner picture drawn at `orientation`.
    ///
    /// The fixed half is the inner panel's native top half: the one Device
    /// Hub keeps facing the viewer, measured with the device upright, where the
    /// inner picture is drawn `landscapeRight` and that half is on the right.
    /// Taken from the framebuffer rather than the screen, so it turns with the
    /// device. Across runs rightward for a vertical crease and upward for a
    /// horizontal one, as the renderer's crease axes do.
    static func fixedSide(innerDrawnIn orientation: Orientation) -> Double {
        let topHalf = orientation.displayedPoint(surfaceX: 0.5, surfaceY: 0.25)
        if FoldCreaseGeometry.creaseRunsVertically(in: orientation) {
            return topHalf.x > 0.5 ? 1 : -1
        }
        return topHalf.y < 0.5 ? 1 : -1
    }
}
