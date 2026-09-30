// SPDX-License-Identifier: GPL-3.0-or-later

/// Command-specific device codes kept beside the device handlers. The shared
/// `CLIErrorCode` type owns the failure envelope and remains command-agnostic.
extension CLIErrorCode {
    /// `device attach` named a simulator that is shut down or shutting down.
    static let deviceNotBooted = CLIErrorCode(rawValue: "device.notBooted")
}
