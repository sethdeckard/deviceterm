// SPDX-License-Identifier: GPL-3.0-or-later
//
// HardwareButton: the `pane.input.button` targets. Shared wire enum so
// the GUI/CLI and the daemon spell the button names once. The rawValue
// is the wire string. The daemon-only mapping to the CoreSimulatorBridge
// C enum (`bridgeValue`) lives in `HardwareButton+Bridge.swift` (Daemon)
// It can't live here because DaemonProtocol must stay Foundation-only.
// `CaseIterable` backs the daemon's "must be one of: …" validation error.

public enum HardwareButton: String, Sendable, Equatable, CaseIterable {
    case home
    case lock
    case side
    case applePay
    case siri
    /// watchOS Digital Crown *press*, the Home-equivalent. (The crown
    /// *rotation* is analog input; see `pane.input.crown`.)
    case digitalCrown
}
