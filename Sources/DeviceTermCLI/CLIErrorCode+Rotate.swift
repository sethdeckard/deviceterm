// SPDX-License-Identifier: GPL-3.0-or-later

/// Command-specific rotate codes kept beside the rotate handler. The shared
/// `CLIErrorCode` type owns the failure envelope and remains command-agnostic.
extension CLIErrorCode {
    static let rotateUnconfirmed = CLIErrorCode(rawValue: "rotate.unconfirmed")
    static let rotateConfirmationUnsupported = CLIErrorCode(rawValue: "rotate.confirmationUnsupported")
    static let inputRefused = CLIErrorCode(rawValue: "input.refused")
}
