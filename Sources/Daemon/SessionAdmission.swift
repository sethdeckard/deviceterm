// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Whether a session id is admissible right now, and (when it is) the live
/// incarnation the request is authorized under. `.ready(incarnation:)` admits
/// the session; a `nil` incarnation means "admissible, unpinned" for a manager
/// that tracks no incarnation or for a test lookup. `.notReady` blocks with the
/// retryable code while the id is mid-registration or mid-teardown.
/// `.absent` means the id is gone (terminal). Derived from
/// `SessionManager.admission(for:)`.
public enum SessionAdmission: Sendable, Equatable {
    case ready(incarnation: UInt64?)
    case notReady
    case absent
}
