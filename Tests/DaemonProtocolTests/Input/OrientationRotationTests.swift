// SPDX-License-Identifier: GPL-3.0-or-later

@testable import DaemonProtocol
import Testing

/// Pure unit tests for the relative-rotation cycle: the internal 90°
/// steps on `Orientation` and the `RotationDirection.applied(to:)` the
/// daemon resolves a `pane.input.rotate` direction with. The cycle must
/// close cleanly, and the two directions must be inverses of each other at
/// every orientation, or a repeated Rotate Left walks somewhere the device
/// isn't.
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

    @Test(
        "each direction applies its own step",
        arguments: Orientation.allCases
    )
    func directionAppliesTheMatchingStep(_ orientation: Orientation) {
        #expect(RotationDirection.left.applied(to: orientation) == orientation.rotatedLeft)
        #expect(RotationDirection.right.applied(to: orientation) == orientation.rotatedRight)
    }

    @Test("wire values are the words a client sends")
    func directionRawValuesArePinned() {
        #expect(RotationDirection.left.rawValue == "left")
        #expect(RotationDirection.right.rawValue == "right")
        #expect(RotationDirection.allCases.count == 2)
    }
}
