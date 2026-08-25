// SPDX-License-Identifier: GPL-3.0-or-later

/// The 90° step behind a relative rotate.
///
/// `pane.input.rotate` takes either an absolute orientation or a
/// direction; the daemon resolves a direction against the pane's
/// tracked control orientation using these two steps, so the Device
/// menu's Rotate Left/Right, `deviceterm rotate left`, and an agent all
/// advance from the same value.
///
/// Cycle reference is Apple's `UIDeviceOrientation` axis convention
/// (`landscapeLeft` = home button on the right, when viewed by the
/// user). Counterclockwise (Rotate Left) from portrait lands on
/// `landscapeLeft`; clockwise (Rotate Right) lands on
/// `landscapeRight`. The cycle is closed under both directions, so
/// repeated requests walk through every orientation and wrap.
///
/// The steps are internal because `RotationDirection.applied(to:)` is
/// their only caller. That method is public, so this doesn't stop a client
/// resolving a direction itself; the reason to send a direction unresolved
/// is that only the daemon holds the base worth resolving against.
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
