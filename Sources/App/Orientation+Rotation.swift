// SPDX-License-Identifier: GPL-3.0-or-later
//
// Orientation+Rotation: relative 90° steps for the Device menu's
// "Rotate Left / Rotate Right" items. The daemon's
// `pane.input.rotate` takes an absolute `Orientation`; user-facing
// rotate actions are inherently relative, so the menu translates
// "Rotate Left" into "the orientation 90° counterclockwise of the
// pane's current one" before calling the wire RPC.
//
// Cycle reference is Apple's `UIDeviceOrientation` axis convention
// (`landscapeLeft` = home button on the right, when viewed by the
// user). Counterclockwise (Rotate Left) from portrait lands on
// `landscapeLeft`; clockwise (Rotate Right) lands on
// `landscapeRight`. The cycle is closed under both directions, so
// repeated taps walk through every orientation and wrap.
//
// Lives on the App side rather than DaemonProtocol: the cycle is a
// UX affordance modeled on Apple's Simulator.app menu, not a wire
// concept any daemon-side code needs.

import DaemonProtocol

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
