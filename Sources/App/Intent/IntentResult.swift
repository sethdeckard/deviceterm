// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// What `IntentDispatcher.dispatch(_:)` returns to the
/// caller after handling a `RouteIntent`.
///
/// Read-only intents return `.data` with a committed workspace projection.
/// Mutations wait for the Router or AppKit delegate to commit, then return
/// `.data` with a `WorkspaceMutationReceipt` naming the resulting objects.
/// The subscriber serializes that response for the waiting CLI caller.
///
/// `.error` carries an `IntentError` with a stable code +
/// human-readable hint so the caller can render either a CLI error line
/// or a menu alert sheet.
enum IntentResult: Sendable, Equatable {
    case data(IntentResponse)
    case error(IntentError)
}
