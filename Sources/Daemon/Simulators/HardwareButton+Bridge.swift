// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import DaemonProtocol

/// The daemon-only mapping from the shared `HardwareButton` wire enum
/// (DaemonProtocol) to CoreSimulatorBridge's private `CSBHardwareButton`
/// C enum.
///
/// This is NOT a protocol conformance (so the AGENTS.md "conformances on
/// the primary type" rule doesn't apply): it's a daemon-only computed
/// property that physically cannot live on `HardwareButton` itself.
/// `HardwareButton` is in the Foundation-only DaemonProtocol module, which
/// must never link CoreSimulatorBridge. An extension in the Daemon module
/// is the only legal home.
extension HardwareButton {
    var bridgeValue: CSBHardwareButton {
        switch self {
        case .home:
            return .home

        case .lock:
            return .lock

        case .side:
            return .sideButton

        case .applePay:
            return .applePay

        case .siri:
            return .siri

        case .digitalCrown:
            return .digitalCrown
        }
    }
}
