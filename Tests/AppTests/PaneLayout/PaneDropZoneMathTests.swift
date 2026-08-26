// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import CoreGraphics
import Testing

/// PaneDropZoneMath: pin the cursor → drop zone mapping. The
/// function is the source of truth for which pane drop zone the
/// cursor is over during a pane drag; getting these boundaries wrong
/// makes the drop indicator land in surprising places.
struct PaneDropZoneMathTests {
    private let frame = CGRect(x: 0, y: 0, width: 400, height: 200)

    @Test
    func cursorOutsideFrameReturnsNil() {
        #expect(PaneDropZoneMath.zone(forCursor: .init(x: -10, y: 10), in: frame) == nil)
        #expect(PaneDropZoneMath.zone(forCursor: .init(x: 500, y: 100), in: frame) == nil)
    }

    @Test
    func cursorInTrueCenterIsCenterZone() {
        let cursor = CGPoint(x: frame.midX, y: frame.midY)
        #expect(PaneDropZoneMath.zone(forCursor: cursor, in: frame) == .center)
    }

    @Test
    func cursorNearLeftEdgeIsLeftHalf() {
        // edgeFraction = 0.25 → left zone is x < 100.
        let cursor = CGPoint(x: 40, y: frame.midY)
        #expect(PaneDropZoneMath.zone(forCursor: cursor, in: frame) == .leftHalf)
    }

    @Test
    func cursorNearRightEdgeIsRightHalf() {
        // Right zone is x > 300.
        let cursor = CGPoint(x: 350, y: frame.midY)
        #expect(PaneDropZoneMath.zone(forCursor: cursor, in: frame) == .rightHalf)
    }

    @Test
    func cursorNearTopEdgeIsTopHalf() {
        // Top zone is y >= 150 (top of a 200pt frame at edgeFraction 0.25).
        let cursor = CGPoint(x: frame.midX, y: 180)
        #expect(PaneDropZoneMath.zone(forCursor: cursor, in: frame) == .topHalf)
    }

    @Test
    func cursorNearBottomEdgeIsBottomHalf() {
        // Bottom zone is y <= 50.
        let cursor = CGPoint(x: frame.midX, y: 20)
        #expect(PaneDropZoneMath.zone(forCursor: cursor, in: frame) == .bottomHalf)
    }

    @Test
    func topBeatsLeftCornerPriority() {
        // Top-left corner is in both top and left zones; the
        // documented order favors top/bottom over left/right so
        // corners always pick the vertical-split insertion.
        let cursor = CGPoint(x: 20, y: 180)
        #expect(PaneDropZoneMath.zone(forCursor: cursor, in: frame) == .topHalf)
    }

    @Test
    func nonOriginFrameOffsetsCorrectly() {
        let offset = CGRect(x: 100, y: 100, width: 400, height: 200)
        let cursor = CGPoint(x: 300, y: 200)  // frame.midX = 300, midY = 200.
        #expect(PaneDropZoneMath.zone(forCursor: cursor, in: offset) == .center)
    }
}
