// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// What `IntentDispatcher.dispatch(_:)` returns to the
/// caller after handling a `RouteIntent`.
///
/// Mutating intents return `.ok` once the Router has accepted the
/// route (the actual GUI reconcile happens shortly after on the
/// MainActor; mutating intents use optimistic-ok semantics rather than
/// instrumenting every Route with a completion handle). Read-only
/// intents (`tabInfo`, `paneInfo`, `windowsList`) return `.data`
/// carrying the wire-format response struct from DaemonProtocol.
/// CLI callers serialize results to a JSON receipt; menu callers either
/// present an actionable failure or discard a benign outcome.
///
/// `.error` carries an `IntentError` with a stable code +
/// human-readable hint so the caller can render either a CLI error line
/// or a menu alert sheet.
enum IntentResult: Sendable, Equatable {
    case ok
    case data(IntentResponse)
    case error(IntentError)
}
