// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What Device Hub can do to the pane that just attached. Named from what
/// the user will see happen, not from any Device Hub internal, because
/// that is what the alert has to describe.
///
/// Unlike `SimulatorShutdownHazard` there is no "no hazard" case. Each
/// pane kind has exactly one, and neither can be turned off: Device Hub's
/// shutdown-on-quit default has no reachable setting, and control of a
/// physical device is exclusive with nothing to configure.
enum DeviceHubHazard: Equatable {
    /// A sim pane. Quitting Device Hub shuts down every booted Simulator,
    /// including ones DeviceTerm booted and Device Hub never opened.
    case simulatorShutdownOnQuit

    /// A physical-device pane. Both apps can mirror the device at once,
    /// but only one can drive it, and interacting from the other moves
    /// control there.
    case deviceControlContention
}
