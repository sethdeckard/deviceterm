// SPDX-License-Identifier: GPL-3.0-or-later
//
// SessionDispatchContext: task-local carrying the authenticated
// session id of the connection that's currently dispatching a method.
//
// Handlers run inside `RPCConnection`'s dispatch task; the dispatcher
// reads the connection's `authenticatedSession` (the result of
// `session.authenticate`) and binds it here before calling the
// handler, so per-method code that needs the originating session id
// (`AppCommandMethods.publishVerb` stamping `originatingSessionId`
// onto the AppCommand it publishes is the one consumer) can read it
// without a per-call wire-shape change.
//
// Why a task-local and not a JSON-injected field:
//   - The wire shape stays clean. CLI senders don't have to know about
//     the field, daemon-side Codable structs don't have to allow for
//     a `_originSessionId` field that's only meaningful on a subset
//     of methods.
//   - No per-call JSON re-encoding for the dispatcher.
//   - Task-locals propagate across `await` boundaries inside the same
//     task, which is the dispatcher → handler flow we already have.
//
// Subscriptions don't propagate the value past the initial-handler
// call (the producer task runs in a different context), but the only
// subscription that cares about originating identity,
// `app.commands`, is the GUI's drain, not a per-call handler.

import Foundation

public enum SessionDispatchContext {
    /// The dispatching connection's authenticated session id as a
    /// UUID string, or nil for daemon-wide unauthenticated callers.
    /// Set by `RPCConnection.dispatch` around the handler invocation;
    /// read by handlers that need to attribute the call.
    @TaskLocal public static var originatingSessionId: String?
}
