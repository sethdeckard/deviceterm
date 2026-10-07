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
    func aBentHingeNarrowsThePictureAndGrowsItsOuterEdges() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: 90))
        #expect(crease.outerAcross < 1)
        // The outer edges come toward the viewer, so they are the long ones.
        // Getting this the wrong way round draws the device from behind: a
        // tent pointing at the viewer rather than a book opening toward them.
        #expect(crease.outerAlong > 1)
        #expect(crease.scale == 1)
    }

    /// Measured off Device Hub's window at three hinge angles read back with
    /// `devicectl`. Both ratios are independent of how large the window was
    /// drawn: the taper is the crease's height over the outer edges', and the
    /// width is the picture's width over the crease's height, relative to the
    /// same ratio flat.
    @Test("the bend matches what Device Hub draws", arguments: [
        (130.0, 0.955, 0.949), (88.6, 0.927, 0.756), (47.5, 0.906, 0.4475)
    ])
    func bendMatchesTheReferenceRenderer(degrees: Double, taper: Double, width: Double) throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: degrees))
        #expect(abs(1 / crease.outerAlong - taper) < 0.01)
        #expect(abs(crease.outerAcross - width) < 0.01)
    }

    @Test
    func closingTheHingeBendsThePictureFurther() throws {
        let nearlyFlat = try #require(FoldCreaseGeometry.crease(degrees: 170))
        let bent = try #require(FoldCreaseGeometry.crease(degrees: book))
        let steep = try #require(FoldCreaseGeometry.crease(degrees: 60))
        #expect(nearlyFlat.outerAcross > bent.outerAcross)
        #expect(bent.outerAcross > steep.outerAcross)
    }

    // MARK: - Halves

    @Test
    func aVerticalCreaseKeepsFullHeightAtTheCrease() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: book))
        let halves = FoldCreaseGeometry.halves(of: rect, foldedAbout: rect, crease: crease, vertical: true)
        // The crease stays in the screen plane, so it keeps the rect's full
        // height on the rect's centre line.
        #expect(halves.leading.creaseLow.x == rect.midX)
        #expect(halves.trailing.creaseLow.x == rect.midX)
        #expect(abs(halves.leading.creaseLow.y - rect.minY) < 1e-9)
        #expect(abs(halves.leading.creaseHigh.y - rect.maxY) < 1e-9)
        // The outer edges come toward the viewer, so they grow past the rect
        // vertically while the turn draws them inward.
        #expect(halves.leading.outerLow.y < rect.minY)
        #expect(halves.leading.outerHigh.y > rect.maxY)
        #expect(halves.leading.outerLow.x > rect.minX)
        #expect(halves.trailing.outerLow.x < rect.maxX)
    }

    @Test
    func aHorizontalCreaseSwapsTheAxes() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: book))
        let halves = FoldCreaseGeometry.halves(of: rect, foldedAbout: rect, crease: crease, vertical: false)
        #expect(halves.leading.creaseLow.y == rect.midY)
        #expect(abs(halves.leading.creaseLow.x - rect.minX) < 1e-9)
        #expect(abs(halves.leading.creaseHigh.x - rect.maxX) < 1e-9)
        #expect(halves.leading.outerLow.x < rect.minX)
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
        #expect(abs(halves.leading.outerLow.y - rect.minY) < 0.5)
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
        // no-op. At `book` the turn draws the edge in by about 4% of the
        // width, less than the turn alone would because the perspective
        // pushes it back out.
        #expect(leadingOuterEdge(crease).x > 0.03)
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
    func theGrowthIsUndoneAlongTheEdgeToo() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: book))
        // The top of the leading outer edge, which the perspective pushed
        // outward past the picture's own top edge.
        let corner = CGPoint(x: 0.5 - crease.outerAcross / 2, y: 0.5 - crease.outerAlong / 2)
        let flat = try #require(
            FoldCreaseGeometry.flattened(unitPoint: corner, crease: crease, vertical: true)
        )
        #expect(abs(flat.x) < 1e-6)
        #expect(abs(flat.y) < 1e-6)
    }

    /// Undoing a scaled fold has to take the scale back out, or a pane drawn
    /// smaller than Device Hub misses every tap toward the edges.
    @Test("a drawn point flattens back to where it came from", arguments: [
        (true, 1.0), (true, 0.9), (false, 1.0), (false, 0.85)
    ])
    func projectionRoundTrips(vertical: Bool, scale: Double) throws {
        var crease = try #require(FoldCreaseGeometry.crease(degrees: 70))
        crease.scale = scale
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        for flat in [CGPoint(x: 0.2, y: 0.3), CGPoint(x: 0.85, y: 0.6), CGPoint(x: 0.5, y: 0.05)] {
            let drawn = FoldCreaseGeometry.projected(flat, in: unit, crease: crease, vertical: vertical)
            let back = try #require(
                FoldCreaseGeometry.flattened(unitPoint: drawn, crease: crease, vertical: vertical)
            )
            #expect(abs(back.x - flat.x) < 1e-9)
            #expect(abs(back.y - flat.y) < 1e-9)
        }
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

    /// With scale 1, points on the crease retain their flat positions,
    /// including the bezel's endpoints.
    @Test
    func nothingOnTheCreaseIsMagnified() throws {
        let shape = try crease()
        let bezel = screen.insetBy(dx: -inset, dy: -inset)
        let onTheCrease = CGPoint(x: screen.midX, y: bezel.minY)
        let bent = FoldCreaseGeometry.projected(
            onTheCrease, in: screen, crease: shape, vertical: true
        )
        #expect(abs(bent.x - screen.midX) < 1e-9)
        #expect(abs(bent.y - bezel.minY) < 1e-9)
    }

    @Test
    func thePicturesOwnCornersAreTheFoldsReference() throws {
        let shape = try crease()
        let corner = CGPoint(x: screen.minX, y: screen.minY)
        let bent = FoldCreaseGeometry.projected(
            corner, in: screen, crease: shape, vertical: true
        )
        // The picture's corner lands exactly where the crease's own fractions
        // put the outer edge, which is what the renderer draws to.
        let along = (bent.y - screen.midY) / (screen.minY - screen.midY)
        let across = (bent.x - screen.midX) / (screen.minX - screen.midX)
        #expect(abs(along - shape.outerAlong) < 1e-9)
        #expect(abs(across - shape.outerAcross) < 1e-9)
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
        // Using the picture's half-width places the bezel's outer corner
        // farther toward the viewer than the picture's edge.
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
    /// Where the crease meets the picture's lower edge. The crease keeps its
    /// flat length, so that is the flat edge itself.
    private let creaseEnd = 1.0

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
        let atEdge = try #require(flattened(CGPoint(x: 0.5, y: creaseEnd), shape))
        #expect(abs(atEdge.y - 1) < 1e-9)
        // A hair further out must read further out, not snap back.
        let justPast = try #require(
            flattened(CGPoint(x: 0.5, y: creaseEnd + 0.004), shape)
        )
        #expect(justPast.y > 1)
    }

    @Test
    func theCoordinateRisesMonotonicallyAcrossTheEdge() throws {
        let shape = try crease()
        var previous = -Double.infinity
        for step in 0...12 {
            let y = creaseEnd - 0.02 + Double(step) * 0.005
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

/// The fold drawn as large as Device Hub draws it where the view has room, and
/// no larger than the view where it does not.
struct FoldCreaseFitTests {
    /// A landscape picture with its bezel margin, the shape a Fit Screen pane
    /// gives an open Duo.
    private let picture = CGRect(x: 18, y: 18, width: 600, height: 420)
    private let margin: CGFloat = 18

    private func corners(of crease: FoldCreaseGeometry.Crease) -> [CGPoint] {
        let frame = picture.insetBy(dx: -margin, dy: -margin)
        let bent = FoldCreaseGeometry.halves(
            of: frame, foldedAbout: picture, crease: crease, vertical: true
        )
        return [bent.leading, bent.trailing].flatMap {
            [$0.outerLow, $0.outerHigh, $0.creaseHigh, $0.creaseLow]
        }
    }

    @Test
    func aViewWithRoomDrawsDeviceHubsSize() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: 60))
        let roomy = picture.insetBy(dx: -margin, dy: -margin).insetBy(dx: 0, dy: -200)
        let fitted = FoldCreaseGeometry.fitted(
            crease, picture: picture, margin: margin, within: roomy, vertical: true
        )
        #expect(fitted.scale == 1)
    }

    /// A Fit Screen pane, where the flat frame already touches the view. The
    /// grown edges have nowhere to go, so the whole fold draws smaller.
    @Test("a full view shrinks the fold until it fits", arguments: [150.0, 120.0, 60.0, 10.0])
    func aFullViewShrinksTheFoldUntilItFits(degrees: Double) throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: degrees))
        let bounds = picture.insetBy(dx: -margin, dy: -margin)
        let fitted = FoldCreaseGeometry.fitted(
            crease, picture: picture, margin: margin, within: bounds, vertical: true
        )
        #expect(fitted.scale < 1)
        for corner in corners(of: fitted) {
            #expect(bounds.insetBy(dx: -1e-9, dy: -1e-9).contains(corner))
        }
        // As large as fits, not merely small enough: some corner touches.
        let touching = corners(of: fitted).contains {
            abs($0.y - bounds.minY) < 1e-6 || abs($0.y - bounds.maxY) < 1e-6
        }
        #expect(touching)
    }

    /// A scale left on the crease by an earlier fit does not carry over: each
    /// fit starts again from Device Hub's size.
    @Test
    func aStaleScaleDoesNotCarryOver() throws {
        var crease = try #require(FoldCreaseGeometry.crease(degrees: 90))
        crease.scale = 0.5
        let fitted = FoldCreaseGeometry.fitted(
            crease,
            picture: picture,
            margin: margin,
            within: picture.insetBy(dx: -900, dy: -900),
            vertical: true
        )
        #expect(fitted.scale == 1)
    }
}
