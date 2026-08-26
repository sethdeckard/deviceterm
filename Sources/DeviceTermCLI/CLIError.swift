// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Failures the CLI driver renders during command execution.
///
/// The three cases map onto the three exit paths the driver renders:
/// a transport problem, a structured daemon `.error` body, and the
/// "not running inside a deviceterm tab" case, which carries its own
/// unprefixed stderr body.
enum CLIError: Error {
    case transport(String)
    case daemon(code: Int, message: String)
    /// The CLI was run outside a deviceterm tab (no session creds in the
    /// env). The associated message is the stderr body (no `deviceterm:`
    /// prefix); the driver renders it.
    case notInTab(String)
}
