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
        view.setDisplayFrame(inset: 12, screenCornerRadius: 40)
        #expect(view.redrawRequests == 1)
    }

    @Test
    func theSameDisplayFrameDoesNot() {
        // The wrapper pushes its geometry on every layout pass; an unchanged
        // push must not cost a draw.
        let view = SimulatorContentView()
        view.setDisplayFrame(inset: 12, screenCornerRadius: 40)
        view.setDisplayFrame(inset: 12, screenCornerRadius: 40)
        #expect(view.redrawRequests == 1)
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
