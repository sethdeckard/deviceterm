// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum CaptureError: Error {
    case noMatchingWindow(bundleID: String)
    /// More than one running process can be the target. Content capture
    /// also treats more than one eligible window owner as ambiguous, since
    /// front-most would then pick between instances rather than between
    /// windows. A PNG of the wrong instance is worse than no PNG, because
    /// nothing about it looks wrong.
    case ambiguousTarget(bundleID: String, pids: [pid_t])
    /// The target publishes more than one menu-bar item, so which one is
    /// the status badge would be a guess. The daemon vends exactly one.
    case ambiguousStatusItem(bundleID: String, count: Int)
    /// An accessibility read needed to locate the status item failed. Kept
    /// distinct from absence: a badge nobody could read is not a badge that
    /// isn't there, and reporting it as hidden would look exactly like the
    /// legitimate zero-sims state.
    case statusItemUnreadable(bundleID: String)
    /// Repeated attempts could not tie a capture to a stable, readable badge
    /// frame, so no screenshot can be said to be of the badge.
    case statusItemUnstable(bundleID: String)
    /// The target's accessibility tree nests an application inside itself,
    /// the known degenerate read. Carries its own case because the remedy is
    /// specific and not obvious: restart the harness. Reported as a failure
    /// rather than skipped, since a walk that finds no menu bar in such a
    /// tree would otherwise answer "no badge".
    case statusItemTreeDegenerate(bundleID: String)
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
