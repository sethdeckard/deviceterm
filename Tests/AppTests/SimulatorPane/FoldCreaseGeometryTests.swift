// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import CoreGraphics
import DaemonProtocol
import Foundation
import Testing

/// The geometry a foldable's picture bends through, and the inverse the
/// input path takes back out of it.
///
/// Both the renderer and the bezel scale the same `Crease`, so these fractions
/// are what keeps a bent frame around a bent picture. The round-trip tests
/// matter most: rendering and input use the projection in opposite directions,
/// and only one of them is visible when it is wrong.
struct FoldCreaseGeometryTests {
    /// The angle the fold bar's `book` posture asks for.
    private let book = FoldPosture.book.degrees
    /// An arbitrary off-origin, non-square rect, so an axis mix-up shows.
    private let rect = CGRect(x: 100, y: 200, width: 400, height: 300)

    @Test
    func aFlatHingeHasNoCrease() {
        #expect(FoldCreaseGeometry.crease(degrees: 180) == nil)
    }

    @Test("angles that produce no crease", arguments: [
        180.0, 179.5, 179.0, -1.0, 181.0, 360.0
    ])
    func reportsNoCrease(degrees: Double) {
        #expect(FoldCreaseGeometry.crease(degrees: degrees) == nil)
    }

    @Test
    func aBentHingeNarrowsThePictureAndPinchesItAtTheCrease() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: 90))
        #expect(crease.outerAcross < 1)
        // The crease is the edge that recedes, so it is the short one. Getting
        // this the wrong way round draws the device from behind: a tent
        // pointing at the viewer rather than a book opening toward them.
        #expect(crease.creaseAlong < 1)
    }

    @Test("the taper matches what Device Hub draws", arguments: [
        (84.4, 0.890), (102.2, 0.905), (124.7, 0.928)
    ])
    func taperMatchesTheReferenceRenderer(degrees: Double, expected: Double) throws {
        // Pins the perspective strength. The bend is cosmetic, so the tolerance
        // is generous; what it guards is a change to `viewerDistance` silently
        // drifting the pane away from the renderer it sits beside.
        let crease = try #require(FoldCreaseGeometry.crease(degrees: degrees))
        #expect(abs(crease.creaseAlong - expected) < 0.02)
    }

    @Test
    func closingTheHingeBendsThePictureFurther() throws {
        let nearlyFlat = try #require(FoldCreaseGeometry.crease(degrees: 170))
        let bent = try #require(FoldCreaseGeometry.crease(degrees: book))
        let steep = try #require(FoldCreaseGeometry.crease(degrees: 60))
        #expect(nearlyFlat.outerAcross > bent.outerAcross)
        #expect(bent.outerAcross > steep.outerAcross)
    }

    /// Without this the two halves are mirror-image trapezoids of identical
    /// colour, which reads as a picture squeezed from both sides rather than
    /// as a fold.
    @Test
    func theHalfTurnedTowardTheLightIsBrighter() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: book))
        #expect(crease.leadingShade > crease.trailingShade)
        #expect(crease.trailingShade > 0)
        #expect(crease.leadingShade <= 1)
    }

    @Test
    func aSteeperFoldDarkensTheHalfTurnedAway() throws {
        let bent = try #require(FoldCreaseGeometry.crease(degrees: book))
        let steep = try #require(FoldCreaseGeometry.crease(degrees: 60))
        #expect(steep.trailingShade < bent.trailingShade)
    }

    // MARK: - Halves

    @Test
    func aVerticalCreaseKeepsFullHeightAtTheOuterEdges() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: book))
        let halves = FoldCreaseGeometry.halves(of: rect, foldedAbout: rect, crease: crease, vertical: true)
        // The crease stays on the rect's centre line and pulls in vertically,
        // because it is the edge that recedes.
        #expect(halves.leading.creaseLow.x == rect.midX)
        #expect(halves.trailing.creaseLow.x == rect.midX)
        #expect(halves.leading.creaseLow.y > rect.minY)
        #expect(halves.leading.creaseHigh.y < rect.maxY)
        // The outer edges sit in the screen plane, so they keep the rect's
        // full height and only move inward.
        #expect(halves.leading.outerLow.y == rect.minY)
        #expect(halves.leading.outerHigh.y == rect.maxY)
        #expect(halves.leading.outerLow.x > rect.minX)
        #expect(halves.trailing.outerLow.x < rect.maxX)
    }

    @Test
    func aHorizontalCreaseSwapsTheAxes() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: book))
        let halves = FoldCreaseGeometry.halves(of: rect, foldedAbout: rect, crease: crease, vertical: false)
        #expect(halves.leading.creaseLow.y == rect.midY)
        #expect(halves.leading.creaseLow.x > rect.minX)
        #expect(halves.leading.creaseHigh.x < rect.maxX)
        #expect(halves.leading.outerLow.x == rect.minX)
        #expect(halves.leading.outerLow.y > rect.minY)
    }

    @Test
    func aFlatRectIsUnchangedByTheHalvesItWouldSplitInto() throws {
        // Just under the flat cutoff, so the halves sit within a whisker of
        // the rect's own edges. This pins the threshold to a visually flat
        // result rather than an arbitrary number.
        let crease = try #require(FoldCreaseGeometry.crease(degrees: 178.9))
        let halves = FoldCreaseGeometry.halves(of: rect, foldedAbout: rect, crease: crease, vertical: true)
        #expect(abs(halves.leading.outerLow.x - rect.minX) < 0.5)
        #expect(abs(halves.leading.creaseLow.y - rect.minY) < 0.5)
    }

    // MARK: - Undoing the bend

    /// The point the renderer puts the leading half's outer edge at, in the
    /// displayed unit coordinates the input path works in.
    private func leadingOuterEdge(_ crease: FoldCreaseGeometry.Crease) -> CGPoint {
        CGPoint(x: 0.5 - crease.outerAcross / 2, y: 0.5)
    }

    @Test
    func theCentreOfThePictureDoesNotMove() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: book))
        let flat = try #require(
            FoldCreaseGeometry.flattened(
                unitPoint: CGPoint(x: 0.5, y: 0.5), crease: crease, vertical: true
            )
        )
        #expect(abs(flat.x - 0.5) < 1e-9)
        #expect(abs(flat.y - 0.5) < 1e-9)
    }

    /// The whole point of the inverse: a click on the bent picture's edge is a
    /// click on the guest's edge, not on the fraction of it the fold left
    /// under the cursor.
    @Test
    func aClickOnTheBentEdgeReachesTheEdgeOfTheGuestScreen() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: book))
        let flat = try #require(
            FoldCreaseGeometry.flattened(
                unitPoint: leadingOuterEdge(crease), crease: crease, vertical: true
            )
        )
        #expect(abs(flat.x) < 1e-6)
    }

    @Test
    func theBentEdgeSitsWellInsideWhereTheFlatEdgeWas() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: book))
        // Guards the test above against passing because the projection is a
        // no-op: at `book` the edge has to have moved a long way.
        #expect(leadingOuterEdge(crease).x > 0.05)
    }

    @Test
    func aPointTheFoldTurnedAwayFromMapsOffTheScreen() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: book))
        // Inside the flat rect, outside the bent picture. It maps past the
        // guest's edge rather than being rejected, because the off-screen
        // gesture path needs it to stay continuous; the strict entry point is
        // what refuses it, and `SimGestureMathCreaseBoundsTests` covers that.
        let vacated = CGPoint(x: leadingOuterEdge(crease).x / 2, y: 0.5)
        let flat = try #require(
            FoldCreaseGeometry.flattened(unitPoint: vacated, crease: crease, vertical: true)
        )
        #expect(flat.x < 0)
    }

    @Test
    func theTaperIsUndoneAlongTheCreaseToo() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: book))
        // The top of the crease, which the perspective pulled inward from the
        // picture's own top edge.
        let corner = CGPoint(x: 0.5, y: 0.5 - crease.creaseAlong / 2)
        let flat = try #require(
            FoldCreaseGeometry.flattened(unitPoint: corner, crease: crease, vertical: true)
        )
        #expect(abs(flat.x - 0.5) < 1e-9)
        #expect(abs(flat.y) < 1e-6)
    }

    @Test
    func undoingAHorizontalCreaseWorksOnTheOtherAxis() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: book))
        let edge = CGPoint(x: 0.5, y: 0.5 - crease.outerAcross / 2)
        let flat = try #require(
            FoldCreaseGeometry.flattened(unitPoint: edge, crease: crease, vertical: false)
        )
        #expect(abs(flat.y) < 1e-6)
        #expect(abs(flat.x - 0.5) < 1e-9)
    }

    // MARK: - Which way the crease runs

    /// Measured on the device: the hinge divides the inner panel along its
    /// framebuffer's height, and opening the Duo puts it in landscape, which
    /// turns that texture a quarter turn and stands the crease up.
    @Test("crease axis per orientation", arguments: [
        (Orientation.portrait, false),
        (Orientation.portraitUpsideDown, false),
        (Orientation.landscapeLeft, true),
        (Orientation.landscapeRight, true)
    ])
    func creaseAxisFollowsOrientation(orientation: Orientation, vertical: Bool) {
        #expect(FoldCreaseGeometry.creaseRunsVertically(in: orientation) == vertical)
    }
}

/// The bezel is bent through the *picture's* fold, not its own.
///
/// The frame and the picture sit on one rigid half, so one projection has to
/// carry both. Bending the frame about its own centre instead gives it a
/// different depth at the same place, and the two drift apart.
struct FoldCreaseBezelAlignmentTests {
    private let screen = CGRect(x: 100, y: 200, width: 400, height: 300)
    private let inset: CGFloat = 20

    private func crease() throws -> FoldCreaseGeometry.Crease {
        try #require(FoldCreaseGeometry.crease(degrees: 100))
    }

    /// The invariant that separates the two models. The picture's own edge
    /// lies in the screen plane, so a point there is at zero depth and keeps
    /// its position along the crease whatever the hinge is doing. Bending the
    /// frame about its own wider centre puts that same place at a depth it
    /// does not have, and shrinks it.
    @Test
    func nothingAtThePicturesEdgeIsForeshortened() throws {
        let shape = try crease()
        let bezel = screen.insetBy(dx: -inset, dy: -inset)
        let onTheEdge = CGPoint(x: screen.minX, y: bezel.minY)
        let bent = FoldCreaseGeometry.projected(
            onTheEdge, in: screen, crease: shape, vertical: true
        )
        #expect(abs(bent.y - bezel.minY) < 1e-9)
    }

    @Test
    func thePicturesOwnCornersAreTheFoldsReference() throws {
        let shape = try crease()
        let corner = CGPoint(x: screen.minX, y: screen.minY)
        let bent = FoldCreaseGeometry.projected(
            corner, in: screen, crease: shape, vertical: true
        )
        // At the edge the only change is the turn, with no perspective in it.
        #expect(abs(bent.y - screen.minY) < 1e-9)
        #expect(abs((bent.x - screen.midX) / (screen.minX - screen.midX) - cos(shape.turn)) < 1e-9)
    }

    @Test
    func theFrameStaysOutsideThePictureOnEveryEdge() throws {
        let shape = try crease()
        let bezel = screen.insetBy(dx: -inset, dy: -inset)
        let picture = FoldCreaseGeometry.halves(
            of: screen, foldedAbout: screen, crease: shape, vertical: true
        )
        let frame = FoldCreaseGeometry.halves(
            of: bezel, foldedAbout: screen, crease: shape, vertical: true
        )
        #expect(frame.leading.outerLow.x < picture.leading.outerLow.x)
        #expect(frame.leading.outerLow.y < picture.leading.outerLow.y)
        #expect(frame.leading.outerHigh.y > picture.leading.outerHigh.y)
        #expect(frame.leading.creaseLow.y < picture.leading.creaseLow.y)
        #expect(frame.leading.creaseHigh.y > picture.leading.creaseHigh.y)
        // Past the picture's edge the half keeps going and comes toward the
        // viewer, so the frame's outer corner is magnified outward rather than
        // sitting flat. A frame bent about its own centre puts that corner at
        // zero depth and leaves it exactly on the flat rect.
        #expect(frame.leading.outerLow.y < bezel.minY - 0.01)
        #expect(frame.leading.outerHigh.y > bezel.maxY + 0.01)
    }

    @Test
    func theCreaseOfTheFrameSitsOnThePicturesCrease() throws {
        let shape = try crease()
        let bezel = screen.insetBy(dx: -inset, dy: -inset)
        let frame = FoldCreaseGeometry.halves(
            of: bezel, foldedAbout: screen, crease: shape, vertical: true
        )
        #expect(abs(frame.leading.creaseLow.x - screen.midX) < 1e-9)
        #expect(abs(frame.trailing.creaseLow.x - screen.midX) < 1e-9)
    }
}

/// Coordinates either side of the picture's edge, which the off-screen gesture
/// path depends on being continuous.
struct FoldCreaseOffScreenContinuityTests {
    private func crease() throws -> FoldCreaseGeometry.Crease {
        try #require(FoldCreaseGeometry.crease(degrees: 90))
    }

    private func flattened(
        _ unit: CGPoint,
        _ shape: FoldCreaseGeometry.Crease
    ) -> CGPoint? {
        FoldCreaseGeometry.flattened(unitPoint: unit, crease: shape, vertical: true)
    }

    /// Coordinates have to keep rising past the bent edge. A drag leaving the
    /// picture at the crease is how the system edge gesture starts, and the
    /// band it keys on sits above 1.
    @Test
    func leavingThePictureAtTheCreaseKeepsGoingPastOne() throws {
        let shape = try crease()
        let atEdge = try #require(flattened(CGPoint(x: 0.5, y: 0.5 + shape.creaseAlong / 2), shape))
        #expect(abs(atEdge.y - 1) < 1e-9)
        // A hair further out must read further out, not snap back.
        let justPast = try #require(
            flattened(CGPoint(x: 0.5, y: 0.5 + shape.creaseAlong / 2 + 0.004), shape)
        )
        #expect(justPast.y > 1)
    }

    @Test
    func theCoordinateRisesMonotonicallyAcrossTheEdge() throws {
        let shape = try crease()
        var previous = -Double.infinity
        for step in 0...12 {
            let y = 0.5 + shape.creaseAlong / 2 - 0.02 + Double(step) * 0.005
            let flat = try #require(flattened(CGPoint(x: 0.5, y: y), shape))
            #expect(flat.y > previous)
            previous = flat.y
        }
    }

    @Test
    func pastTheOuterEdgeAcrossKeepsGoingToo() throws {
        let shape = try crease()
        let atEdge = try #require(flattened(CGPoint(x: 0.5 - shape.outerAcross / 2, y: 0.5), shape))
        #expect(abs(atEdge.x) < 1e-9)
        let justPast = try #require(
            flattened(CGPoint(x: 0.5 - shape.outerAcross / 2 - 0.01, y: 0.5), shape)
        )
        #expect(justPast.x < 0)
    }
}
