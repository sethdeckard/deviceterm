// SPDX-License-Identifier: GPL-3.0-or-later

/// What a `pane.input.rotate` request asks for, as one
/// value. `RotateParams` carries the two possibilities as mutually
/// exclusive optional fields because that is the JSON shape; a producer
/// building from this can't emit the both-set or neither-set request
/// the handler would reject.
public enum RotationTarget: Sendable, Equatable {
    /// Rotate to this orientation, wherever the device is now.
    case absolute(Orientation)
    /// Rotate one relative 90° step. A physical-device backend forwards the
    /// direction directly; a Simulator resolves it from confirmed display
    /// observation.
    case relative(RotationDirection)

    /// The absolute target, or nil when this is relative. Paired with
    /// `direction` so projecting back onto the wire's two fields
    /// happens one way, in one place.
    public var orientation: Orientation? {
        switch self {
        case let .absolute(orientation):
            return orientation

        case .relative:
            return nil
        }
    }

    /// The requested direction, or nil when this is absolute.
    public var direction: RotationDirection? {
        switch self {
        case .absolute:
            return nil

        case let .relative(direction):
            return direction
        }
    }
}
