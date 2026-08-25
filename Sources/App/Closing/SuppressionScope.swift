// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// Scope qualifier picked alongside "Don't ask again". Each scope maps
/// to a different storage tier in `CloseSuppressionState`.
enum SuppressionScope: Sendable {
    /// This window only, held in-memory as `[WindowID: …]`.
    case window
    /// Until DeviceTerm quits, held in an in-memory app-singleton.
    case session
    /// Permanent, quit-prompt only. Persisted to file.
    case appExit
    /// Permanent across every prompt of the same track. Persisted to
    /// file; on the sim track it cross-writes both sim keys, on the
    /// multi-pane track it writes only `tab-close-multi-pane`.
    case always
}
