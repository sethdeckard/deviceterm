// SPDX-License-Identifier: GPL-3.0-or-later
//
// RPCMethodError. Typed error a method handler can throw to return
// a structured RPC error response with a specific code + message.
//
// `RPCConnection.dispatch` catches this case specifically: it
// surfaces the carried `code` / `message` into the response envelope's
// error body. Untyped errors thrown by handlers still convert to the
// catch-all `serverError` (-32000); this type is for the cases where
// the handler actively wants a specific code on the wire (invalid
// params, unauthorized, not found, etc.).

import Foundation

public struct RPCMethodError: Error, Sendable, Equatable {
    // MARK: Conventional codes

    /// Caller's params didn't validate (missing fields, malformed
    /// UUID/base64, etc.). JSON-RPC's standard `Invalid params` code.
    public static let invalidParamsCode = -32_602

    /// A terminal authentication or session-authorization failure, including
    /// invalid credentials, a missing authenticated context, or a closed or
    /// revoked session. Distinct from `invalidParamsCode` so the client can
    /// distinguish malformed input from an authorization failure.
    public static let unauthorizedCode = -32_001

    /// A retryable readiness failure: the requested identity or resource
    /// cannot be established yet but may become available once restoration,
    /// registration, or a binding completes. One representative (non-
    /// exhaustive) case is a UDS peer authenticating on a live session before
    /// the GUI has bound its terminal (e.g. immediately after a daemon or GUI
    /// restart, before the re-bind lands). Distinct from `unauthorizedCode`
    /// because it is **retryable**: the CLI briefly retries rather than
    /// failing, and the awaited state normally appears within a round-trip. A
    /// hard `unauthorizedCode` here would turn a benign startup race into a
    /// spurious failure; an endless retry on a genuinely-unauthorized peer is
    /// avoided because only these not-yet-ready branches produce this code,
    /// while a wrong terminal is `unauthorizedCode`.
    public static let notReadyCode = -32_002

    /// Caller isn't authorized for the requested method: a terminal
    /// (non-retryable) scope refusal. Role itself is not authority; this
    /// code covers refusals such as a missing live orchestration grant on an
    /// `.orchestratorTab`-tagged method, an unvalidated GUI peer reaching for
    /// a GUI-only method, or a forbidden orchestrator-role mint at
    /// `session.create`. The individual error message describes the applicable
    /// refusal. Distinct from `unauthorizedCode` so a client can distinguish a
    /// terminal scope refusal from invalid or stale session authentication.
    public static let roleViolationCode = -32_011

    /// Reserved, and **deliberately unused on the pane path.** Per-pane
    /// authorization (`PaneCoordinator.authorize`) does not surface a
    /// distinct "you don't own this pane" code: a foreign paneId returns
    /// the same `notFound` (`invalidParams`, "unknown paneId") as an
    /// unknown one, on purpose: a dedicated code would be an existence
    /// oracle, telling a same-user attacker that the UUID names a real,
    /// live, other-session pane. The code stays defined so the wire
    /// vocabulary is stable, but nothing constructs it.
    public static let unlinkedPaneCode = -32_012

    /// CoreSimulator bridge call into AX / HID / display surfaced an
    /// error that's the pane's responsibility to interpret (e.g.
    /// "AX server not ready," "macPlatformElementFromTranslation
    /// returned nil"). Distinct from `serverError` so machine
    /// consumers can dispatch on "the bridge spoke up" without
    /// substring-matching the message. Per-cell "no element at
    /// point" outcomes are NOT this; those are routine per-point
    /// misses in a sweep and surface as a normal empty result.
    public static let bridgeFailedCode = -32_020

    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public static func invalidParams(_ message: String) -> RPCMethodError {
        RPCMethodError(code: invalidParamsCode, message: message)
    }

    public static func unauthorized(_ message: String) -> RPCMethodError {
        RPCMethodError(code: unauthorizedCode, message: message)
    }

    public static func notReady(_ message: String) -> RPCMethodError {
        RPCMethodError(code: notReadyCode, message: message)
    }

    public static func roleViolation(_ message: String) -> RPCMethodError {
        RPCMethodError(code: roleViolationCode, message: message)
    }

    public static func unlinkedPane(_ message: String) -> RPCMethodError {
        RPCMethodError(code: unlinkedPaneCode, message: message)
    }
}
