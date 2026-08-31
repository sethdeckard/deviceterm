// SPDX-License-Identifier: GPL-3.0-or-later

/// A stable code in the public CLI JSON failure contract.
///
/// The raw-value wrapper lets feature-specific commands add their own
/// namespace without editing a shared enum. Common cross-command classes
/// live here so callers don't invent synonyms for the same failure.
struct CLIErrorCode: RawRepresentable, Codable, Hashable, Sendable {
    static let invalidUsage = CLIErrorCode(rawValue: "cli.invalidUsage")
    static let internalError = CLIErrorCode(rawValue: "cli.internalError")
    static let sessionRequired = CLIErrorCode(rawValue: "session.required")
    static let sessionUnauthorized = CLIErrorCode(rawValue: "session.unauthorized")
    static let sessionNotReady = CLIErrorCode(rawValue: "session.notReady")
    static let transportUnavailable = CLIErrorCode(rawValue: "transport.unavailable")
    static let transportTimeout = CLIErrorCode(rawValue: "transport.timeout")
    static let transportInterrupted = CLIErrorCode(rawValue: "transport.interrupted")
    static let protocolInvalidResponse = CLIErrorCode(rawValue: "protocol.invalidResponse")
    static let paneNotFound = CLIErrorCode(rawValue: "pane.notFound")
    static let paneAmbiguous = CLIErrorCode(rawValue: "pane.ambiguous")
    static let paneUnavailable = CLIErrorCode(rawValue: "pane.unavailable")
    static let paneBridgeFailed = CLIErrorCode(rawValue: "pane.bridgeFailed")
    static let waitTimeout = CLIErrorCode(rawValue: "wait.timeout")
    static let waitInconclusive = CLIErrorCode(rawValue: "wait.inconclusive")
    static let waitUnsupported = CLIErrorCode(rawValue: "wait.unsupported")
    static let waitUnreachable = CLIErrorCode(rawValue: "wait.unreachable")
    static let waitAmbiguous = CLIErrorCode(rawValue: "wait.ambiguous")
    static let rpcInvalidRequest = CLIErrorCode(rawValue: "rpc.invalidRequest")
    static let rpcMethodNotFound = CLIErrorCode(rawValue: "rpc.methodNotFound")
    static let rpcInvalidParams = CLIErrorCode(rawValue: "rpc.invalidParams")
    static let rpcServerError = CLIErrorCode(rawValue: "rpc.serverError")
    static let rpcError = CLIErrorCode(rawValue: "rpc.error")

    let rawValue: String
}
