// SPDX-License-Identifier: GPL-3.0-or-later

/// The relative targets `pane.input.rotate` accepts
/// in place of an absolute orientation. Shared wire enum; raw values are
/// what a client puts on the wire and what `deviceterm rotate` takes as
/// its argument. `CaseIterable` backs the daemon's validation error
/// message.
public enum RotationDirection: String, Sendable, Equatable, CaseIterable {
    /// 90° counterclockwise, matching the Device menu's Rotate Left.
    case left
    /// 90° clockwise, matching the Device menu's Rotate Right.
    case right

    /// The orientation this direction reaches from `orientation`.
    /// Simulator rotation applies this to the pane's confirmed display
    /// orientation; physical-device rotation forwards the direction instead.
    public func applied(to orientation: Orientation) -> Orientation {
        switch self {
        case .left:
            return orientation.rotatedLeft

        case .right:
            return orientation.rotatedRight
        }
    }
}
