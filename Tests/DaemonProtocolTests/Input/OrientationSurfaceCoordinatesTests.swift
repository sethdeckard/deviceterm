// SPDX-License-Identifier: GPL-3.0-or-later
//
// These tests pin displayed-to-native mappings measured against a live
// simulator; drift sends landscape taps to the wrong native point.

import DaemonProtocol
import Testing

struct OrientationSurfaceCoordinatesTests {
    /// Portrait is the identity, which is what keeps an unrotated device
    /// unaffected by any of this.
    @Test
    func portraitIsTheIdentity() {
        for (x, y) in [(0.0, 0.0), (0.5, 0.5), (0.2, 0.7), (1.0, 1.0)] {
            let point = Orientation.portrait.surfacePoint(displayedX: x, displayedY: y)
            #expect(point.x == x)
            #expect(point.y == y)
        }
    }

    /// The landscape transforms must be exact inverses.
    @Test
    func landscapeLeftAndRightAreInverses() {
        let (x, y) = (0.2, 0.7)
        let left = Orientation.landscapeLeft.surfacePoint(displayedX: x, displayedY: y)
        let leftThenRight = Orientation.landscapeRight.surfacePoint(
            displayedX: left.x,
            displayedY: left.y
        )
        let right = Orientation.landscapeRight.surfacePoint(displayedX: x, displayedY: y)
        let rightThenLeft = Orientation.landscapeLeft.surfacePoint(
            displayedX: right.x,
            displayedY: right.y
        )
        #expect(abs(leftThenRight.x - x) < 1e-9)
        #expect(abs(leftThenRight.y - y) < 1e-9)
        #expect(abs(rightThenLeft.x - x) < 1e-9)
        #expect(abs(rightThenLeft.y - y) < 1e-9)
    }

    /// 180° twice is the identity.
    @Test
    func upsideDownIsInvolution() {
        let (x, y) = (0.3, 0.8)
        let once = Orientation.portraitUpsideDown.surfacePoint(displayedX: x, displayedY: y)
        let twice = Orientation.portraitUpsideDown.surfacePoint(
            displayedX: once.x,
            displayedY: once.y
        )
        #expect(abs(twice.x - x) < 1e-9)
        #expect(abs(twice.y - y) < 1e-9)
    }

    /// Where the displayed top-left lands on the native panel, per
    /// orientation. These are the corners the empirical work pinned.
    @Test(
        "displayed top-left maps to the right native corner",
        arguments: [
            (Orientation.portrait, 0.0, 0.0),
            (.landscapeLeft, 1.0, 0.0),
            (.portraitUpsideDown, 1.0, 1.0),
            (.landscapeRight, 0.0, 1.0)
        ]
    )
    func topLeftCorner(orientation: Orientation, expectedX: Double, expectedY: Double) {
        let point = orientation.surfacePoint(displayedX: 0, displayedY: 0)
        #expect(point.x == expectedX)
        #expect(point.y == expectedY)
    }

    /// Out-of-range input is rotated, not clamped. The bezel-origin edge
    /// gestures depend on it: a touch just below the displayed screen
    /// arrives as `y > 1` and has to land past whichever native edge the
    /// current orientation puts there.
    @Test
    func outOfRangeInputIsRotatedNotClamped() {
        let below = Orientation.landscapeLeft.surfacePoint(displayedX: 0.5, displayedY: 1.02)
        #expect(abs(below.x - (1 - 1.02)) < 1e-9)
        #expect(abs(below.y - 0.5) < 1e-9)
        #expect(below.x < 0, "the off-screen coordinate was clamped into range")
    }
}
