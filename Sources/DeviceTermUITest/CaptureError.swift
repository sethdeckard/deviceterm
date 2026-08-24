// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum CaptureError: Error {
    case noMatchingWindow(bundleID: String)
    /// More than one running application or eligible window owner can be
    /// the target, so capture selection is ambiguous: front-most (or
    /// smallest, for the status item) would pick between instances rather
    /// than between windows. A PNG of the wrong instance is worse than no
    /// PNG, because nothing about it looks wrong.
    case ambiguousTarget(bundleID: String, pids: [pid_t])
    /// `--out` names an existing path that isn't a regular file (a
    /// directory, socket, FIFO, symlink, device). Refused rather than
    /// treated as a PNG path: the hidden-badge path clears a stale file
    /// there, and we must never remove (or write over) a special file
    /// the caller pointed `--out` at (unlinking a live socket would break
    /// its listener; removing a directory would recurse).
    case outputNotAFile(path: String)
    /// `--out` exists but couldn't be inspected (permission, I/O). Distinct
    /// from "absent", so an inaccessible stale capture is never mistaken for
    /// a clear path.
    case outputUnreadable(path: String, underlying: String)
    /// Removing a stale capture at `--out` failed.
    case cleanupFailed(path: String, underlying: String)
    /// ScreenCaptureKit refused. Most often a missing Screen Recording
    /// grant for whichever process is attributed (the resident harness
    /// once bundled; the terminal app when run as a bare binary).
    case captureFailed(underlying: String)
}
