// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import DaemonProtocol
import IOSurface
import Testing

/// The sim pane's Metal view draws only when asked. What is pinned: the
/// view is paused with `needsDisplay` honoured, and a redraw is requested
/// for mounting, a new surface, a cleared surface, an orientation change,
/// a display-geometry change, and a drawable-size change, while reapplying
/// the same lease, orientation, or display geometry, or clearing an
/// already-empty view, requests nothing.
///
/// Requests are counted through `redrawRequests` rather than read off
/// `needsDisplay`: AppKit records that flag only for a window-backed view
/// and clears it once it has serviced the display, so an offscreen test
/// window stops recording it after its first display. The one window-backed
/// case reads the flag on a fresh mount, where AppKit does record it.
@MainActor
struct SimulatorContentViewRedrawTests {
    /// A plain rounded display, for the pushes that only care that the
    /// geometry changed.
    private static let rounded = DeviceBezelLayout.Corners(
        topLeft: 40,
        topRight: 40,
        bottomLeft: 40,
        bottomRight: 40
    )

    private let frame = NSRect(x: 0, y: 0, width: 64, height: 64)

    private func makeSurface() throws -> IOSurfaceRef {
        let props: [String: Any] = [
            kIOSurfaceWidth as String: 4,
            kIOSurfaceHeight as String: 4,
            kIOSurfaceBytesPerElement as String: 4,
            kIOSurfacePixelFormat as String: 0x42_47_52_41
        ]
        return try #require(IOSurfaceCreate(props as CFDictionary))
    }

    /// The simulator-frame shape: no use-count, no release.
    private func unleased(_ surface: IOSurfaceRef) -> SurfaceLease {
        SurfaceLease(
            surface: surface,
            paneId: "p1",
            subscriptionToken: UUID(),
            leaseEpoch: 0,
            generation: 0,
            onRelease: nil
        )
    }

    @Test
    func initialisesAsChangeDriven() {
        let view = SimulatorContentView()
        #expect(view.isPaused)
        #expect(view.enableSetNeedsDisplay)
        #expect(view.redrawRequests == 0)
    }

    @Test
    func enteringAWindowRequestsADraw() {
        // Mounting requests a redraw, so a frame that arrived while the
        // view was unplaced, or the frame a tab switch carries back in, has
        // display work pending on placement. Placement fires the backing
        // and drawable-size callbacks as well, so this proves only that at
        // least one mount-related callback requested. Reading AppKit's flag
        // too proves the request was recorded where a display cycle would
        // find it.
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let view = SimulatorContentView()
        view.frame = frame
        window.contentView?.addSubview(view)
        #expect(view.redrawRequests >= 1)
        #expect(view.needsDisplay)
    }

    @Test
    func aNewOrientationRequestsADraw() {
        let view = SimulatorContentView()
        view.setOrientation(.landscapeLeft)
        #expect(view.redrawRequests == 1)
    }

    @Test
    func theSameOrientationDoesNot() {
        let view = SimulatorContentView()
        view.setOrientation(.portrait)
        #expect(view.redrawRequests == 0)
    }

    @Test
    func aNewDisplayFrameRequestsADraw() {
        let view = SimulatorContentView()
        view.setDisplayFrame(inset: 12, screenCorners: Self.rounded)
        #expect(view.redrawRequests == 1)
    }

    @Test
    func theSameDisplayFrameDoesNot() {
        // The wrapper pushes its geometry on every layout pass; an unchanged
        // push must not cost a draw.
        let view = SimulatorContentView()
        view.setDisplayFrame(inset: 12, screenCorners: Self.rounded)
        view.setDisplayFrame(inset: 12, screenCorners: Self.rounded)
        #expect(view.redrawRequests == 1)
    }

    /// One corner moving is a changed frame. A display can be rounder at one
    /// end than the other, so the gate cannot watch a single radius.
    @Test
    func oneChangedCornerRequestsADraw() {
        let view = SimulatorContentView()
        view.setDisplayFrame(inset: 12, screenCorners: Self.rounded)
        view.setDisplayFrame(
            inset: 12,
            screenCorners: DeviceBezelLayout.Corners(
                topLeft: 40,
                topRight: 40,
                bottomLeft: 40,
                bottomRight: 6
            )
        )
        #expect(view.redrawRequests == 2)
    }

    @Test
    func aLeaseRequestsADraw() throws {
        let view = SimulatorContentView()
        view.setSurface(unleased(try makeSurface()))
        #expect(view.redrawRequests == 1)
        #expect(view.surfaceSize == CGSize(width: 4, height: 4))
    }

    @Test
    func theSameLeaseDoesNotRequestASecondDraw() throws {
        // The render binding re-applies the held lease on any unrelated
        // change; the same delivery carries no new pixels.
        let view = SimulatorContentView()
        let lease = unleased(try makeSurface())
        view.setSurface(lease)
        view.setSurface(lease)
        #expect(view.redrawRequests == 1)
    }

    @Test
    func aNilLeaseWithNoSurfaceDoesNot() {
        let view = SimulatorContentView()
        view.setSurface(nil)
        #expect(view.redrawRequests == 0)
    }

    @Test
    func aNilLeaseClearingASurfaceDoes() throws {
        // Clearing has to present the clear colour, or the stale frame
        // stays on screen.
        let view = SimulatorContentView()
        view.setSurface(unleased(try makeSurface()))
        view.setSurface(nil)
        #expect(view.redrawRequests == 2)
    }

    @Test
    func aDrawableSizeChangeRequestsADraw() {
        let view = SimulatorContentView()
        view.mtkView(view, drawableSizeWillChange: CGSize(width: 10, height: 10))
        #expect(view.redrawRequests == 1)
    }
}

/// A posed foldable turns over when its side changes, draws posed only while
/// it must, and leaves nothing running once it's done.
@MainActor
struct SimulatorContentViewTurnoverTests {
    private func fold(closed: Bool, showsInnerFrame: Bool) -> SimulatorContentView.PosedFold {
        SimulatorContentView.PosedFold(
            closed: closed,
            openTurn: 1,
            showsInnerFrame: showsInnerFrame,
            innerOrientation: .landscapeRight,
            coverOrientation: .portrait,
            innerSize: CGSize(width: 8, height: 12),
            coverSize: CGSize(width: 6, height: 9),
            family: .phone
        )
    }

    @Test
    func aTurnoverEndsAndLeavesNothingRunning() async throws {
        let view = SimulatorContentView()
        var reports: [Bool] = []
        view.onPosedDrawingChange = { reports.append($0) }
        view.setPosedFold(fold(closed: false, showsInnerFrame: true))
        // At rest on the lit panel, the frame on show is drawn as it is.
        #expect(!view.drawsPosedFold)
        // Off screen, as after a tab switch: the display link never ticks,
        // and the deadline has to end it. The cover isn't lit yet, so the
        // closed device stays posed after the turnover.
        view.setPosedFold(fold(closed: true, showsInnerFrame: true))
        #expect(view.drawsPosedFold)
        try await Task.sleep(nanoseconds: UInt64((FoldTurnover.duration + 0.3) * 1e9))
        #expect(view.drawsPosedFold)
        // The cover lights: back to the frame as it is.
        view.setPosedFold(fold(closed: true, showsInnerFrame: false))
        #expect(!view.drawsPosedFold)
        #expect(reports == [true, false])
    }

    @Test
    func aTurnoverOntoTheLitPanelEndsPlain() async throws {
        let view = SimulatorContentView()
        var reports: [Bool] = []
        view.onPosedDrawingChange = { reports.append($0) }
        view.setPosedFold(fold(closed: true, showsInnerFrame: false))
        view.setPosedFold(fold(closed: false, showsInnerFrame: true))
        #expect(view.drawsPosedFold)
        for _ in 0..<200 where view.drawsPosedFold {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(!view.drawsPosedFold)
        #expect(reports == [true, false])
    }

    @Test
    func theFirstPoseDoesNotTurnOver() {
        let view = SimulatorContentView()
        view.setPosedFold(fold(closed: true, showsInnerFrame: false))
        #expect(!view.drawsPosedFold)
        view.setPosedFold(nil)
        view.setPosedFold(fold(closed: false, showsInnerFrame: true))
        #expect(!view.drawsPosedFold)
    }
}

/// A two-finger gesture never starts while the device is drawn posed, from
/// any input: the picture isn't laid out the way the gesture geometry
/// assumes.
@MainActor
struct SimulatorContentViewPosedGestureTests {
    private final class PinchCounter: SimulatorInputDelegate {
        var pinches = 0
        var simulatorPaneSupportsLiveTouchInput: Bool { true }
        var simulatorPaneSupportsMultitouchInput: Bool { true }
        var simulatorPaneSupportsEdgeGesture: Bool { false }
        func simulatorPaneDidTap(at point: CGPoint) {}
        func simulatorPaneDidTouch(at point: CGPoint, phase: TouchPhase, isEdgeGesture: Bool) {}
        func simulatorPaneDidMultitouch(phase: TouchPhase, finger1: CGPoint, finger2: CGPoint) {}
        func simulatorPaneDidSwipe(from start: CGPoint, to end: CGPoint, durationMs: Int) {}
        func simulatorPaneDidPinch(fromF1: CGPoint, fromF2: CGPoint, toF1: CGPoint, toF2: CGPoint, durationMs: Int) {
            pinches += 1
        }
        func simulatorPaneKeyDown(keyCode: UInt16) {}
        func simulatorPaneKeyUp(keyCode: UInt16) {}
        func simulatorPaneDidCrown(delta: Double) {}
    }

    /// Pinches out of one Command-scroll over the middle of a view showing a
    /// surface, posed or not.
    private func pinchesFromCommandScroll(posed: Bool, leaning: Bool = false) async throws -> Int {
        let view = SimulatorContentView()
        view.frame = CGRect(x: 0, y: 0, width: 200, height: 300)
        // The cover's frame when leaning, so the cover is the lit panel.
        let props: [String: Any] = [
            kIOSurfaceWidth as String: leaning ? 6 : 8,
            kIOSurfaceHeight as String: leaning ? 9 : 12,
            kIOSurfaceBytesPerElement as String: 4,
            kIOSurfacePixelFormat as String: 0x42_47_52_41
        ]
        let surface = try #require(IOSurfaceCreate(props as CFDictionary))
        view.applyFrame(
            lease: SurfaceLease(
                surface: surface,
                paneId: "p1",
                subscriptionToken: UUID(),
                leaseEpoch: 0,
                generation: 0,
                onRelease: nil
            ),
            traceSequence: nil
        )
        let counter = PinchCounter()
        view.inputDelegate = counter
        if posed || leaning {
            // Shown closed while the inner panel is still lit: drawn posed.
            // Leaning, the cover is lit and the hinge part open.
            let fold = SimulatorContentView.PosedFold(
                closed: true,
                openTurn: 1,
                closedHinge: leaning ? 0.5 : 0,
                showsInnerFrame: !leaning,
                innerOrientation: .portrait,
                coverOrientation: .portrait,
                innerSize: CGSize(width: 8, height: 12),
                coverSize: CGSize(width: 6, height: 9),
                family: .phone
            )
            view.setPosedFold(fold)
            #expect(view.drawsPosedFold)
        }
        let scroll = try #require(
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 40, wheel2: 0, wheel3: 0)
        )
        scroll.flags = .maskCommand
        let screenHeight = NSScreen.screens.first?.frame.height ?? 1_000
        scroll.location = CGPoint(x: 100, y: screenHeight - 150)
        view.scrollWheel(with: try #require(NSEvent(cgEvent: scroll)))
        // The scroll gesture lands once it has been still for a moment.
        try await Task.sleep(nanoseconds: 400_000_000)
        return counter.pinches
    }

    @Test
    func aCommandScrollPinchesAPaneAtRest() async throws {
        #expect(try await pinchesFromCommandScroll(posed: false) == 1)
    }

    @Test
    func aCommandScrollPinchesALeaningCover() async throws {
        // Posed for the lean, but the cover is the lit panel, mapped through.
        #expect(try await pinchesFromCommandScroll(posed: false, leaning: true) == 1)
    }

    @Test
    func aCommandScrollDoesNotPinchAPosedDevice() async throws {
        #expect(try await pinchesFromCommandScroll(posed: true) == 0)
    }
}
