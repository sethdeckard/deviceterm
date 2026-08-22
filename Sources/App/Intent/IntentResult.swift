// SPDX-License-Identifier: GPL-3.0-or-later
//
// IntentResult: what `IntentDispatcher.dispatch(_:)` returns to the
// caller after handling a `RouteIntent`.
//
// Mutating intents return `.ok` once the Router has accepted the
// route (the actual GUI reconcile happens shortly after on the
// MainActor; mutating intents use optimistic-ok semantics rather than
// instrumenting every Route with a completion handle). Read-only
// intents (`tabInfo`, `paneInfo`, `windowsList`) return `.data`
// carrying the wire-format response struct from DaemonProtocol.
// CLI sources serialize to a JSON receipt; menu sources render a
// sheet; deep-link sources currently ignore data results (URL
// handlers don't have a result channel).
//
// `.error` carries an `IntentError` with a stable code +
// human-readable hint so the source layer can render either a CLI
// error line, a menu alert sheet, or a URL-handler failure log.

import DaemonProtocol
import Foundation

enum IntentResult: Sendable, Equatable {
    case ok
    case data(IntentResponse)
    case error(IntentError)
}

/// The data shape returned by read-only intents. Wraps the wire
/// payload types from DaemonProtocol so the GUI's source layer
/// (`AppCommandSubscriber`) can JSON-encode them directly into
/// `AppCommandResult.data` without an intermediate translation.
enum IntentResponse: Sendable, Equatable {
    case tabInfo(TabInfoPayload)
    case paneInfo(PaneInfoPayload)
    case windowsList([WindowInfoPayload])
    case tabCapture(TabCapturePayload)
    /// Awaited outcome of `tab set-protected`: committed vs still
    /// converging (`committed == false`). A definite rejection is an
    /// `.error`, not this.
    case tabSetProtected(TabSetProtectedResult)
}
