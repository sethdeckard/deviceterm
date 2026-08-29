// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Failures the CLI driver renders during command execution.
enum CLIError: Error {
    case classified(code: CLIErrorCode, message: String)
    case daemon(code: Int, message: String)
    /// The CLI was run outside a deviceterm tab (no session creds in the
    /// env). The associated message is the stderr body (no `deviceterm:`
    /// prefix); the driver renders it.
    case notInTab(String)

    static func transport(_ message: String) -> CLIError {
        .transportInterrupted(message)
    }

    static func transportUnavailable(_ message: String) -> CLIError {
        .classified(code: .transportUnavailable, message: message)
    }

    static func transportTimeout(_ message: String) -> CLIError {
        .classified(code: .transportTimeout, message: message)
    }

    static func transportInterrupted(_ message: String) -> CLIError {
        .classified(code: .transportInterrupted, message: message)
    }

    static func invalidResponse(_ message: String) -> CLIError {
        .classified(code: .protocolInvalidResponse, message: message)
    }

    static func paneNotFound(_ message: String) -> CLIError {
        .classified(code: .paneNotFound, message: message)
    }

    static func paneAmbiguous(_ message: String) -> CLIError {
        .classified(code: .paneAmbiguous, message: message)
    }

    static func paneUnavailable(_ message: String) -> CLIError {
        .classified(code: .paneUnavailable, message: message)
    }
}
