// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Task-local carrying the authenticated
/// session id of the connection that's currently dispatching a method.
///
/// Handlers run inside a dispatch task; both the UDS and XPC dispatchers
/// read the connection's `authenticatedSession` (the result of
/// `session.authenticate`) and bind it here before calling the handler, so
/// per-method code that needs the originating session id can read it
/// without a per-call wire-shape change. App-command attribution
/// (`AppCommandMethods.publishVerb` stamping `originatingSessionId`),
/// session-list filtering, and physical-device attribution all read it.
///
/// Why a task-local and not a JSON-injected field:
///   - The wire shape stays clean. CLI senders don't have to know about
///     the field, daemon-side Codable structs don't have to allow for
///     a `_originSessionId` field that's only meaningful on a subset
///     of methods.
///   - No per-call JSON re-encoding for the dispatcher.
///   - Task-locals propagate across `await` boundaries inside the same
///     task, which is the dispatcher → handler flow we already have.
///
/// Subscriptions don't propagate the value past the initial-handler
/// call (the producer task runs in a different context), but the only
/// subscription that cares about originating identity,
/// `app.commands`, is the GUI's drain, not a per-call handler.
public enum SessionDispatchContext {
    /// The dispatching connection's authenticated session id as a
    /// UUID string, or nil for daemon-wide unauthenticated callers.
    /// Set by `RPCConnection.dispatch` around the handler invocation;
    /// read by handlers that need to attribute the call.
    @TaskLocal public static var originatingSessionId: String?
}
