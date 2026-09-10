// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Read the tab's session credentials, throwing `CLIError.notInTab` when
/// the CLI is run outside a deviceterm tab. The throwing form used by the
/// typed command handlers; the driver maps `.notInTab` to stderr + exit 1.
func readSessionCredentials() throws -> (sessionId: String, cap: String) {
    guard let session = envValue(DeviceTermEnv.session), !session.isEmpty,
        let cap = envValue(DeviceTermEnv.sessionCap), !cap.isEmpty else {
        throw CLIError.notInTab(
            "not inside a deviceterm tab "
            + "(\(DeviceTermEnv.session) / \(DeviceTermEnv.sessionCap) unset)"
        )
    }
    return (session, cap)
}

/// Read the tab's session credentials, or exit with a clear message when
/// the CLI is run outside a deviceterm tab. Exit-based form for the verbs
/// that own their I/O and can't throw (`with-pane`); every other handler
/// uses the throwing `readSessionCredentials`.
func sessionCredentials() -> (sessionId: String, cap: String) {
    guard let creds = try? readSessionCredentials() else {
        writeStderr(
            "deviceterm: not inside a deviceterm tab "
            + "(\(DeviceTermEnv.session) / \(DeviceTermEnv.sessionCap) unset)\n"
            )
        exit(1)
    }
    return creds
}
