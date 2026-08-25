// SPDX-License-Identifier: GPL-3.0-or-later
//
// Orientation+SurfaceCoordinates: the displayed→native coordinate
// rotation the coordinate-bearing touch verbs ride on. The hardware,
// text, rotation, and crown verbs carry no coordinates and never reach
// it.
//
// Two coordinate spaces are easy to confuse:
//
//   - **Native surface space.** CoreSimulator keeps the IOSurface at the
//     device's portrait pixel dimensions whatever the device is doing,
//     and the HID digitizer's ratio field addresses that fixed panel.
//     It never rotates.
//   - **Displayed space.** What the viewer sees. In landscape the app's
//     interface has turned, so its top-left is a different corner of
//     the panel. The accessibility tree reports frames here, because
//     they come from the guest's own UIKit geometry.
//
// The wire contract is displayed space: `(0, 0)` is the top-left of what
// you see. That is the space the GUI's own pointer handling has always
// spoken, and the space accessibility frames are already in, so a caller
// working from a frame needs no rotation of its own (it does still have
// to normalize, since frames are in pixels). The daemon converts to
// native space at its input boundary, against the presentation
// orientation it holds there.
//
// Portrait is the identity, so nothing about an unrotated device
// changes.
//
// The daemon is the only caller. This lives beside `Orientation` rather
// than in the daemon because the wire types whose coordinates it governs
// are defined here, so the contract and the conversion that implements
// it stay together. Clients stop at displayed space and never convert.

public extension Orientation {
    /// Convert a point in displayed space to the device's native
    /// portrait surface space.
    ///
    /// Both coordinates are normalized, and neither is clamped: the HID
    /// contract passes out-of-range values through as off-screen input,
    /// and the bezel-origin edge gestures depend on that (a touch just
    /// below the screen arrives as `y > 1`). The rotation maps such a
    /// point onto whichever native edge the current orientation puts it,
    /// which is the whole point of doing it here.
    func surfacePoint(displayedX x: Double, displayedY y: Double) -> (x: Double, y: Double) {
        switch self {
        case .portrait:
            return (x, y)

        // Displayed top-left (0, 0) is the native top-right (1, 0).
        case .landscapeLeft:
            return (1 - y, x)

        case .portraitUpsideDown:
            return (1 - x, 1 - y)

        // Displayed top-left (0, 0) is the native bottom-left (0, 1).
        case .landscapeRight:
            return (y, 1 - x)
        }
    }
}
