// SPDX-License-Identifier: GPL-3.0-or-later
//
// RotationDirection: the relative targets `pane.input.rotate` accepts
// in place of an absolute orientation. Shared wire enum; raw values are
// what a client puts on the wire and what `deviceterm rotate` takes as
// its argument. `CaseIterable` backs the daemon's validation error
// message.

public enum RotationDirection: String, Sendable, Equatable, CaseIterable {
    /// 90° counterclockwise, matching the Device menu's Rotate Left.
    case left
    /// 90° clockwise, matching the Device menu's Rotate Right.
    case right

    /// The orientation this direction reaches from `orientation`. The
    /// daemon applies it to the pane's tracked control orientation; a
    /// client resolving its own would step from a base the daemon
    /// doesn't hold.
    public func applied(to orientation: Orientation) -> Orientation {
        switch self {
        case .left:
            return orientation.rotatedLeft

        case .right:
            return orientation.rotatedRight
        }
    }
}
