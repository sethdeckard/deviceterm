// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import ApplicationServices
import Foundation

enum AXDumpError: Error, Equatable {
    case appNotRunning(bundleID: String)
    /// The harness lacks the Accessibility grant. Distinct from an AX error
    /// because the fix is a checkbox, not a code change.
    case notTrusted
    case unreadableRoot(bundleID: String)
    /// Several running applications share this bundle identifier, so
    /// choosing an AX root would be arbitrary.
    case ambiguousTarget(bundleID: String, pids: [pid_t])
}
