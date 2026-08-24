// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Standard JSON-RPC-ish error codes for daemon-side responses.
public enum RPCErrorCode {
    /// Method requested isn't in the registry.
    public static let methodNotFound = -32_601
    /// Caller's payload was syntactically invalid JSON / frame.
    public static let invalidRequest = -32_600
    /// Method handler threw an arbitrary error not otherwise typed.
    public static let serverError = -32_000
}
