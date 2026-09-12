// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One failed pane-attach attempt, retained while its GUI placeholder remains.
///
/// The Router normally renders attach errors in the failed placeholder and has
/// no caller waiting for them. An explicit `device attach`, however, awaits the
/// same task so it can return a committed pane. This value preserves the
/// daemon's numeric code and message across that join instead of making the
/// intent layer infer a generic internal failure from the missing pane.
struct PaneAttachFailure: Error, Sendable, Equatable {
    let rpcCode: Int
    let message: String

    init(_ error: any Error) {
        if case let DaemonClientError.daemon(code, message) = error {
            self.rpcCode = code
            self.message = message
        } else {
            // A caller-local timeout or transport/decode failure has no daemon
            // reply code to preserve. It is still a server-side failure from
            // the CLI's perspective, not an intent invariant violation.
            // Mirror the daemon's JSON-RPC server-error value. RPCErrorCode
            // belongs to the daemon executable and cannot cross into App.
            self.rpcCode = -32_000
            self.message = ErrorText.describing(error)
        }
    }
}
