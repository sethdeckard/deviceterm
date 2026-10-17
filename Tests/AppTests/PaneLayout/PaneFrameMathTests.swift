// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import DaemonProtocol
import Testing

@testable import App

struct PaneFrameMathTests {
    @Test
    func topLeftMeasuresFromTheTopEdge() {
        // The upper pane of a vertical stack sits at the larger AppKit y.
        let upper = CGRect(x: 0, y: 400, width: 640, height: 400)
        let lower = CGRect(x: 0, y: 0, width: 640, height: 399)
        #expect(PaneFrameMath.topLeft(upper, inHeight: 800) == CGRect(x: 0, y: 0, width: 640, height: 400))
        #expect(PaneFrameMath.topLeft(lower, inHeight: 800) == CGRect(x: 0, y: 401, width: 640, height: 399))
    }

    @Test
    func wholePointsRoundsEdgesSoNeighborsStayAdjacent() throws {
        let left = try #require(PaneFrameMath.wholePoints(CGRect(x: 0, y: 0, width: 320.4, height: 800)))
        let right = try #require(PaneFrameMath.wholePoints(CGRect(x: 320.4, y: 0, width: 319.6, height: 800)))
        #expect(left == WorkspacePaneFrame(x: 0, y: 0, width: 320, height: 800))
        #expect(right == WorkspacePaneFrame(x: 320, y: 0, width: 320, height: 800))
        #expect(left.x + left.width == right.x)
    }

    @Test("a rectangle without area has no frame", arguments: [
        CGRect.zero,
        CGRect(x: 10, y: 10, width: 0, height: 200),
        CGRect(x: 10, y: 10, width: 200, height: 0.2)
    ])
    func wholePointsDropsEmptyRectangles(rect: CGRect) {
        #expect(PaneFrameMath.wholePoints(rect) == nil)
    }
}
