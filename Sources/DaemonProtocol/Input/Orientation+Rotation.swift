// SPDX-License-Identifier: GPL-3.0-or-later

/// The 90° step behind a relative rotate.
///
/// `pane.input.rotate` takes either an absolute orientation or a
/// direction. Simulator rotation resolves a direction against confirmed
/// display observation using these two steps. Physical-device rotation sends
/// the direction directly and learns the absolute result from the reply.
///
/// Cycle reference is Apple's `UIDeviceOrientation` axis convention
/// (`landscapeLeft` = home button on the right, when viewed by the
/// user). Counterclockwise (Rotate Left) from portrait lands on
/// `landscapeLeft`; clockwise (Rotate Right) lands on
/// `landscapeRight`. The cycle is closed under both directions, so
/// repeated requests walk through every orientation and wrap.
///
/// The steps are internal because `RotationDirection.applied(to:)` is their
/// only caller. Send a relative request unresolved so the selected backend can
/// preserve its own semantics.
extension Orientation {
    /// The orientation reached by rotating 90° counterclockwise from
    /// this one.
    var rotatedLeft: Orientation {
        switch self {
        case .portrait:
            return .landscapeLeft

        case .landscapeLeft:
            return .portraitUpsideDown

        case .portraitUpsideDown:
            return .landscapeRight

        case .landscapeRight:
            return .portrait
        }
    }

    /// The orientation reached by rotating 90° clockwise from this one.
    var rotatedRight: Orientation {
        switch self {
        case .portrait:
            return .landscapeRight

        case .landscapeRight:
            return .portraitUpsideDown

        case .portraitUpsideDown:
            return .landscapeLeft

        case .landscapeLeft:
            return .portrait
        }
    }
}
