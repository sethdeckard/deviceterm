// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Which way Simulator.app can still take a booted sim down. Named from
/// the user's action, not the preference key, because that is what the
/// alert has to describe.
enum SimulatorShutdownHazard: Equatable {
    /// Quitting Simulator.app, which includes closing its last device
    /// window: that closes the app, not just the window.
    case appQuit
    /// Closing one device window while others stay open.
    case windowClose
    /// Both routes are live.
    case both
}
