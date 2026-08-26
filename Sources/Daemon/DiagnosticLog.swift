// SPDX-License-Identifier: GPL-3.0-or-later

import os

/// The daemon's unified-logging channels, named once.
///
/// Four categories, each answering a different question:
///
///   lifecycle  when did this daemon instance start, and why did it exit?
///   xpc        did one connection drop, or did the process go away?
///   attach     what was the daemon doing, and in which phase?
///   session    was a session torn down underneath a pane?
///
/// Separate categories rather than one channel because they are read
/// separately. `lifecycle` alone answers "did it restart". Correlating a pane
/// failure means interleaving all four by timestamp, together with the GUI's own
/// `com.deviceterm` categories.
///
/// PRIVACY: correlation ids, phase names, pids, and counts are `.public` so they
/// survive `log show`. Device UDIDs, session ids, and capabilities are
/// `.private` or omitted.
public enum DiagnosticLog {
    /// The daemon's unified-logging subsystem. The GUI logs under
    /// `com.deviceterm`, so a query spanning both processes must ask for both.
    public static let subsystem = "com.deviceterm.daemon"

    /// When a daemon instance started, and why it exited. `.notice`/`.error`
    /// only, so it is readable from `log show` without `--info`.
    public static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")

    /// XPC connection accept/invalidate milestones.
    public static let xpc = Logger(subsystem: subsystem, category: "xpc")

    /// Device enumeration, backend resolution, and pane creation phases.
    public static let attach = Logger(subsystem: subsystem, category: "attach")

    /// Session readiness, teardown, and subscription revocation.
    public static let session = Logger(subsystem: subsystem, category: "session")
}
