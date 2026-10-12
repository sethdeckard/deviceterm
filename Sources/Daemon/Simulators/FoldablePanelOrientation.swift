// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// How a foldable's device orientation reads on the panel it is showing.
///
/// Both panels report one display orientation. With the cover lit it equals
/// the device orientation. The inner panel is turned a quarter against the
/// cover, so with it lit the reading is the device orientation rotated 90°
/// clockwise: a device held in portrait reads `landscapeRight`.
///
/// A rotation is requested in device terms and confirmed by the display
/// reading, so `resolve` answers both: the device orientation to send and the
/// reading to wait for. Anywhere but a foldable's inner panel the two are the
/// same.
enum FoldablePanelOrientation {
    /// What a rotation request asks the device for, and the reading that
    /// confirms it.
    struct Resolution: Equatable {
        /// The device orientation to send.
        let device: Orientation
        /// The display reading that confirms it.
        let display: Orientation
    }

    /// Resolve `target` against the last confirmed display reading.
    ///
    /// A relative step turns the *device*, so it starts from the device
    /// orientation behind `confirmed`, not from the reading itself. Nil for a
    /// relative step with nothing confirmed to step from, and for a flat
    /// target, which no display reading confirms.
    static func resolve(
        _ target: RotationTarget,
        confirmed: Orientation?,
        onInnerPanel: Bool
    ) -> Resolution? {
        let device: Orientation
        switch target {
        case let .absolute(value):
            device = value

        case let .relative(direction):
            guard let confirmed else { return nil }
            device = direction.applied(to: self.device(forDisplay: confirmed, onInnerPanel: onInnerPanel))

        case .flat:
            return nil
        }
        return Resolution(device: device, display: display(forDevice: device, onInnerPanel: onInnerPanel))
    }

    /// The display reading a device orientation produces.
    static func display(forDevice device: Orientation, onInnerPanel: Bool) -> Orientation {
        guard onInnerPanel else { return device }
        switch device {
        case .portrait:
            return .landscapeRight

        case .landscapeLeft:
            return .portrait

        case .portraitUpsideDown:
            return .landscapeLeft

        case .landscapeRight:
            return .portraitUpsideDown
        }
    }

    /// The device orientation behind a display reading.
    static func device(forDisplay display: Orientation, onInnerPanel: Bool) -> Orientation {
        guard onInnerPanel else { return display }
        switch display {
        case .landscapeRight:
            return .portrait

        case .portrait:
            return .landscapeLeft

        case .landscapeLeft:
            return .portraitUpsideDown

        case .portraitUpsideDown:
            return .landscapeRight
        }
    }
}
