// SPDX-License-Identifier: GPL-3.0-or-later
//
// Orientation+Bridge: the daemon-only mapping from the shared
// Orientation wire enum (DaemonProtocol) to CoreSimulatorBridge's
// private `CSBDeviceOrientation` C enum. Daemon-only computed property,
// not a protocol conformance; see HardwareButton+Bridge.swift for why it
// lives in an extension here rather than on the type.

import CoreSimulatorBridge
import DaemonProtocol

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
