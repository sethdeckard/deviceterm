// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import DaemonProtocol

/// The daemon-only mapping from the shared `Orientation` wire enum
/// (DaemonProtocol) to CoreSimulatorBridge's private
/// `CSBDeviceOrientation` C enum.
///
/// A daemon-only computed property, not a protocol conformance:
/// `Orientation` lives in the Foundation-only DaemonProtocol module, which
/// must never link CoreSimulatorBridge, so an extension in the Daemon
/// module is the only legal home.
extension Orientation {
    var bridgeValue: CSBDeviceOrientation {
        switch self {
        case .portrait:
            return .portrait

        case .portraitUpsideDown:
            return .portraitUpsideDown

        case .landscapeLeft:
            return .landscapeLeft

        case .landscapeRight:
            return .landscapeRight
        }
    }
}
