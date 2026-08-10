// SPDX-License-Identifier: GPL-3.0-or-later
//
// Orientation: the `pane.input.rotate` targets. Shared wire enum; raw
// values match UIKit's `UIDeviceOrientation` names so the GSEvent wire
// format reads them as-is. The daemon-only mapping to the
// CoreSimulatorBridge C enum (`bridgeValue`) lives in
// `Orientation+Bridge.swift` (Daemon). `CaseIterable` backs the daemon's
// validation error message.

public enum Orientation: String, Sendable, Equatable, CaseIterable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight
}
