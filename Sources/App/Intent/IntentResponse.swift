// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

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
