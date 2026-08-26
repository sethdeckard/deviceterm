// SPDX-License-Identifier: GPL-3.0-or-later

/// A cause plus what the user should be told about side effects: why
/// DeviceTerm is asking to be restarted, in the terms the copy needs.
///
/// Separate from `VersionMismatchOutcome`, which stays the mid-session
/// vocabulary and describes one thing: what became of a shutdown request. The
/// recovery ladder can end in several distinguishable states that vocabulary has
/// no words for, and widening it would churn the mid-session path for cases it
/// never reaches.
///
/// The distinctions here are the ones the user needs, not the ones the code finds
/// convenient. Each cause exists because the honest sentence differs: whether the
/// old helper stopped, whether anything replaced it, whether the replacement
/// matches, and whether macOS is still working on the registration. A cause that
/// read the same as its neighbour would be a cause that shouldn't exist.
struct UpdateRestartSituation: Sendable, Equatable {
    let cause: UpdateRestartCause
    /// Whether the launchd registration was torn down and rebuilt, which can
    /// re-surface the system's Background Activity notification. Worth naming
    /// because it is a visible thing DeviceTerm did, not an internal step.
    let reregistered: Bool
    /// Every rung's own words, verbatim, for the details disclosure. Kept so a
    /// bug report carries what the friendly copy deliberately leaves out.
    let detail: String

    init(cause: UpdateRestartCause, detail: String, reregistered: Bool = false) {
        self.cause = cause
        self.detail = detail
        self.reregistered = reregistered
    }
}
