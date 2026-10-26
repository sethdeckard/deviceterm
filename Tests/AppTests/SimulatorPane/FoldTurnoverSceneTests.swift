// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import CoreGraphics
import DaemonProtocol
import Foundation
import Testing

/// The posed quads a turnover paints: the symmetric crease at the open end, the cover
/// as the pane draws it at rest at the closed end, and the painting order.
struct FoldTurnoverSceneTests {
    private let inner = FoldTurnoverScene.Panel(
        width: 500,
        halfHeight: 350,
        hingeInset: 0,
        outerInset: 12,
        alongInset: 15,
        screenHingeRadius: 0,
        screenOuterRadius: 40,
        bodyHingeRadius: 0,
        bodyOuterRadius: 52
    )
    private let cover = FoldTurnoverScene.Panel(
        width: 490,
        halfHeight: 356,
        hingeInset: 20,
        outerInset: 12,
        alongInset: 13,
        screenHingeRadius: 6,
        screenOuterRadius: 42,
        bodyHingeRadius: 18,
        bodyOuterRadius: 54
    )
    private let drawable = CGSize(width: 1_400, height: 1_000)

    private func scene(
        _ pose: FoldPose,
        fixedSide: Double = 1,
        drawable: CGSize? = nil
    ) -> FoldTurnoverScene {
        FoldTurnoverScene(
            inner: inner,
            cover: cover,
            vertical: true,
            fixedSide: fixedSide,
            pose: pose,
            drawable: drawable ?? self.drawable,
            scale: 1
        )
    }

    @Test
    func theOpenEndIsTheSymmetricCrease() throws {
        let crease = try #require(FoldCreaseGeometry.crease(degrees: 37))
        let quads = scene(.open(turn: crease.turn)).quads()
        let picture = try #require(quads.first { $0.fill == .innerPicture })
        // Outer-high corner of the fixed (right) half.
        let outer = picture.vertices[2]
        #expect(abs(Double(outer.position.x) - crease.outerAcross * 500 / 700) < 1e-5)
        #expect(abs(Double(outer.position.y) - crease.outerAlong * 350 / 500) < 1e-5)
        #expect(abs(outer.unit.x - 1) < 1e-6)
    }

    @Test("closed, the cover lands where the pane draws it at rest", arguments: [-1.0, 1.0])
    func theClosedEndIsTheCoverAtRest(fixedSide: Double) throws {
        let quads = scene(.closed, fixedSide: fixedSide).quads()
        let picture = try #require(quads.first { $0.fill == .coverPicture })
        let acrossValues = picture.vertices.map { Double($0.position.x) }
        let alongValues = picture.vertices.map { Double($0.position.y) }
        #expect(abs((acrossValues.min() ?? 0) + 245.0 / 700) < 1e-5)
        #expect(abs((acrossValues.max() ?? 0) - 245.0 / 700) < 1e-5)
        #expect(abs((alongValues.max() ?? 0) - 356.0 / 500) < 1e-5)
        for vertex in picture.vertices {
            #expect(abs(vertex.divisor - 1) < 1e-6)
            // The texture runs the right way round: left edge -1, right +1.
            #expect(abs(Double(vertex.unit.x) - Double(vertex.position.x) / (245.0 / 700)) < 1e-5)
        }
    }

    @Test
    func theFixedHalfIsPaintedFirstAndFramesUnderPictures() {
        let open = scene(.open(turn: 1)).quads().map(\.fill)
        #expect(open == [.frame, .innerPicture, .frame, .innerPicture])
        let pastEdgeOn = scene(FoldPose(fixedTurn: 0, swingTurn: 2)).quads().map(\.fill)
        #expect(pastEdgeOn == [.frame, .innerPicture, .frame, .coverPicture])
    }

    /// A pane fitted tight to the open device: the swinging half, coming
    /// toward the viewer and round to the other side, must never leave it.
    @Test("no frame of a turnover leaves a tight drawable", arguments: [FoldTurnover.Direction.closing, .opening])
    func theDeviceStaysOnTheDrawable(direction: FoldTurnover.Direction) {
        let tight = CGSize(width: 2 * (500 + 12), height: 2 * (350 + 15))
        let openTurn = 71.5 * Double.pi / 180
        for step in 0...40 {
            let elapsed = FoldTurnover.duration * Double(step) / 40
            let pose = FoldTurnover.pose(direction: direction, elapsed: elapsed, openTurn: openTurn)
            for vertex in scene(pose, drawable: tight).quads().flatMap(\.vertices) {
                #expect(abs(vertex.position.x) <= 1 + 1e-5)
                #expect(abs(vertex.position.y) <= 1 + 1e-5)
            }
        }
    }

    /// The real panels, measured as the pane measures them, in a pane that
    /// isn't square: closed, the cover's frame has to hide the fixed inner
    /// half entirely, or the inner picture shows round it and vanishes when
    /// the steady drawing takes over.
    @Test("closed, the cover hides the inner half, leaning or not", arguments: [
        (CGSize(width: 2_400, height: 1_300), 0.0),
        (CGSize(width: 1_300, height: 2_400), 0.0),
        // The widest the device is shown closed at, just short of opening.
        (CGSize(width: 2_400, height: 1_300), FoldTurnover.opensAbove - 1),
        (CGSize(width: 1_300, height: 2_400), FoldTurnover.opensAbove - 1)
    ])
    func theClosedCoverHidesTheInnerHalf(drawable: CGSize, hingeDegrees: Double) throws {
        let scene = try #require(
            FoldTurnoverScene.measuring(
                innerSize: CGSize(width: 2_007, height: 2_853),
                coverSize: CGSize(width: 1_398, height: 2_034),
                innerOrientation: .landscapeRight,
                coverOrientation: .portrait,
                family: .phone,
                drawable: drawable,
                backing: 2,
                insetPoints: 18,
                direction: .closing,
                elapsed: FoldTurnover.duration,
                openTurn: 71.5 * Double.pi / 180,
                closedHinge: hingeDegrees * .pi / 180
            )
        )
        let quads = scene.quads()
        let fixedHalf = quads.prefix(2).flatMap(\.vertices)
        let coverFrame = try #require(quads.last { $0.fill == .frame })
        func bounds(_ vertices: [FoldTurnoverScene.Vertex]) -> CGRect {
            let lefts = vertices.map { CGFloat($0.position.x) }
            let bottoms = vertices.map { CGFloat($0.position.y) }
            return CGRect(
                x: lefts.min() ?? 0,
                y: bottoms.min() ?? 0,
                width: (lefts.max() ?? 0) - (lefts.min() ?? 0),
                height: (bottoms.max() ?? 0) - (bottoms.min() ?? 0)
            )
        }
        let hidden = bounds(fixedHalf)
        let cover = bounds(coverFrame.vertices)
        #expect(cover.insetBy(dx: -1e-4, dy: -1e-4).contains(hidden))
    }
}

/// Shown closed, the device leans with the hinge as Device Hub's does, flat
/// only at `0`.
struct FoldClosedLeanTests {
    /// The cover frame's outer edge over its hinge edge, as drawn, with the
    /// hinge at `degrees`.
    private func edgeRatio(degrees: Double) throws -> Double {
        let scene = try #require(
            FoldTurnoverScene.measuring(
                innerSize: CGSize(width: 2_007, height: 2_853),
                coverSize: CGSize(width: 1_398, height: 2_034),
                innerOrientation: .landscapeRight,
                coverOrientation: .portrait,
                family: .phone,
                drawable: CGSize(width: 2_400, height: 2_400),
                backing: 2,
                insetPoints: 18,
                direction: .closing,
                elapsed: FoldTurnover.duration,
                openTurn: 71.5 * Double.pi / 180,
                closedHinge: degrees * .pi / 180
            )
        )
        let frame = try #require(scene.quads().last { $0.fill == .frame })
        // Hinge-low, hinge-high, outer-high, outer-low; the crease runs down
        // the screen here, so an edge's height is its span in y.
        let hinge = abs(Double(frame.vertices[1].position.y - frame.vertices[0].position.y))
        let outer = abs(Double(frame.vertices[2].position.y - frame.vertices[3].position.y))
        return outer / hinge
    }

    @Test
    func atFortyFourDegreesItLeansLikeDeviceHub() throws {
        // Off Device Hub's closed device just after it turned over at 44°: the
        // outer edge stands 1.034 times the hinge edge.
        let ratio = try edgeRatio(degrees: 44)
        #expect(abs(ratio - 1.034) < 0.004)
    }

    @Test
    func itLeansLessAsTheHingeClosesAndLiesFlatAtZero() throws {
        let ratios = try [44.0, 30, 15, 0].map(edgeRatio(degrees:))
        #expect(ratios[0] > ratios[1] && ratios[1] > ratios[2] && ratios[2] > ratios[3])
        #expect(abs(ratios[3] - 1) < 1e-9)
    }
}

/// A click on a leaning cover maps back to where it lands on the cover, the
/// drawing run backwards.
struct FoldCoverPointTests {
    @Test("the cover's own corners map back to the cover's corners", arguments: [
        Orientation.landscapeRight,
        // A horizontal crease, as with the device on its side.
        Orientation.portrait
    ])
    func theCornersRoundTrip(innerOrientation: Orientation) throws {
        let scene = try #require(
            FoldTurnoverScene.measuring(
                innerSize: CGSize(width: 2_007, height: 2_853),
                coverSize: CGSize(width: 1_398, height: 2_034),
                innerOrientation: innerOrientation,
                coverOrientation: innerOrientation == .portrait ? .landscapeLeft : .portrait,
                family: .phone,
                drawable: CGSize(width: 2_400, height: 2_000),
                backing: 2,
                insetPoints: 18,
                direction: .closing,
                elapsed: FoldTurnover.duration,
                openTurn: 71.5 * Double.pi / 180,
                closedHinge: 44 * Double.pi / 180
            )
        )
        let picture = try #require(scene.quads().last { $0.fill == .coverPicture })
        for vertex in picture.vertices {
            // A hair inside the corner, which sits exactly on the edge.
            let inward = SIMD2(Double(vertex.position.x), Double(vertex.position.y)) * 0.999
            guard let point = scene.coverPoint(ndc: inward) else {
                Issue.record("corner \(vertex.position) maps off the cover")
                continue
            }
            let expected = CGPoint(x: (Double(vertex.unit.x) + 1) / 2, y: (1 - Double(vertex.unit.y)) / 2)
            #expect(abs(point.x - expected.x) < 0.01)
            #expect(abs(point.y - expected.y) < 0.01)
        }
        #expect(scene.coverPoint(ndc: SIMD2(0.999, 0.999)) == nil)
    }
}
