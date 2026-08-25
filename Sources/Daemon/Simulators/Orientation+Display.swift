// SPDX-License-Identifier: GPL-3.0-or-later
//
// Orientation+Display: the daemon-only mapping from CoreSimulatorBridge's
// observed `CSBDisplayOrientation` into the shared Orientation wire enum.
// The inverse direction (a rotate target heading for the bridge) lives in
// `Orientation+Bridge.swift`; this one is an observation, so it is
// failable where that one is total.
//
// Daemon-only initializer, not a protocol conformance; see
// HardwareButton+Bridge.swift for why it lives in an extension here rather
// than on the type.

import CoreSimulatorBridge
import DaemonProtocol

extension Orientation {
    /// The pane orientation an observed display value names, or nil when
    /// the display vends no orientation source or reports a value with no
    /// pane meaning. Callers leave their stored orientation alone on nil
    /// rather than flipping the pane to a guess.
    ///
    /// The bridge has already mapped the private surface's
    /// `UIInterfaceOrientation` into device-orientation vocabulary, so this
    /// is a straight rename with no landscape swap left to apply.
    init?(displayValue: CSBDisplayOrientation) {
        switch displayValue {
        case .portrait:
            self = .portrait

        case .portraitUpsideDown:
            self = .portraitUpsideDown

        case .landscapeLeft:
            self = .landscapeLeft

        case .landscapeRight:
            self = .landscapeRight

        default:
            return nil
        }
    }
}
