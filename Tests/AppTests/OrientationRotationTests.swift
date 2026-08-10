// SPDX-License-Identifier: GPL-3.0-or-later
//
// Pure unit tests for the relative-rotation extension on
// `Orientation`. The Device menu's Rotate Left/Right derive their
// next-step from these accessors, so the cycle must close cleanly
// under both directions and be the inverse of each other at every
// orientation.

@testable import App
import DaemonProtocol
import Testing

struct OrientationRotationTests {
    @Test(
        "Rotate Left cycle wraps through every orientation",
        arguments: [
            (Orientation.portrait, Orientation.landscapeLeft),
            (.landscapeLeft, .portraitUpsideDown),
            (.portraitUpsideDown, .landscapeRight),
            (.landscapeRight, .portrait)
        ]
    )
    func rotateLeftAdvancesCorrectly(from: Orientation, expected: Orientation) {
        #expect(from.rotatedLeft == expected)
    }

    @Test(
        "Rotate Right is the inverse of Rotate Left at every orientation",
        arguments: Orientation.allCases
    )
    func rotateRightIsInverseOfRotateLeft(_ orientation: Orientation) {
        #expect(orientation.rotatedLeft.rotatedRight == orientation)
        #expect(orientation.rotatedRight.rotatedLeft == orientation)
    }

    @Test(
        "Four rotations in either direction land on the starting orientation",
        arguments: Orientation.allCases
    )
    func fourRotationsCycle(_ orientation: Orientation) {
        let left = orientation.rotatedLeft.rotatedLeft.rotatedLeft.rotatedLeft
        let right = orientation.rotatedRight.rotatedRight.rotatedRight.rotatedRight
        #expect(left == orientation)
        #expect(right == orientation)
    }
}
