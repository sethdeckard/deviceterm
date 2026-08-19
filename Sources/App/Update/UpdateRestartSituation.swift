// SPDX-License-Identifier: GPL-3.0-or-later
//
// UpdateRestartSituation: why DeviceTerm is asking to be restarted, in the
// terms the copy needs.
//
// Separate from `VersionMismatchOutcome`, which stays the mid-session
// vocabulary and describes one thing: what became of a shutdown request. The
// recovery ladder can end in several distinguishable states that vocabulary has
// no words for, and widening it would churn the mid-session path for cases it
// never reaches.
//
// The distinctions here are the ones the user needs, not the ones the code finds
// convenient. Each cause exists because the honest sentence differs: whether the
// old helper stopped, whether anything replaced it, whether the replacement
// matches, and whether macOS is still working on the registration. A cause that
// read the same as its neighbour would be a cause that shouldn't exist.

/// The state recovery ended in.
enum UpdateRestartCause: Sendable, Equatable {
    /// Mid-session: the helper was replaced under a running GUI, and the old one
    /// acknowledged the request to stop.
    ///
    /// Named for what the daemon actually promised. `daemon.shutdown` acks
    /// `DaemonMethods.shutdownAckGraceMs` before the process exits, so an
    /// acknowledgement is confirmation of *acceptance*, and neither this name
    /// nor its copy may upgrade that to termination.
    case shutdownAcceptedWhileRunning
    /// Mid-session, and no acknowledgement arrived, so the old helper's state is
    /// genuinely unknown.
    case replacedWhileRunningUnconfirmed(String)
    /// Startup: recovery ran its ladder and no compatible helper is answering.
    ///
    /// Not a claim that every rung ran. The ladder is conditional, and this is
    /// also where a repair rung that was unavailable or failed before its own
    /// teardown lands, so the copy speaks to the outcome rather than the steps.
    case helperCouldNotBeStopped(String)
    /// Startup: the old helper stopped, and what started in its place still
    /// speaks a different wire version. Stopping it again would not converge.
    case replacementStillIncompatible(daemonVersion: String)
    /// Startup: the old helper stopped and nothing answered in its place.
    case replacementDidNotStart(String)
    /// The registration was torn down and could not be stood back up. The helper
    /// is stopped and nothing will start it, which is a different problem from
    /// one that would not stop.
    ///
    /// Only for the case where the teardown is KNOWN to have completed. Anything
    /// less certain is `.registrationStateUnknown`, because this cause's copy
    /// tells the user their helper has definitely stopped.
    case registrationNotRestored(String)
    /// DeviceTerm could not determine or complete the registration's state.
    ///
    /// Reached when a replay of an interrupted repair failed before its own
    /// teardown (the earlier repair may already have torn things down), and when
    /// the marker location could not be resolved at all. In both, the honest
    /// statement is that the state is unknown rather than that the helper
    /// stopped.
    case registrationStateUnknown(String)
    /// The repair outran its deadline and is still running in the background.
    /// Not a failure: it may yet succeed.
    case registrationRepairAbandoned(String)
    /// A launch could not get past another DeviceTerm launch: either its replay
    /// of an interrupted repair outran the deadline, or another copy held the
    /// startup lock for the whole wait, which covers an ordinary startup as well
    /// as a repair.
    ///
    /// The one cause that can repeat across launches by construction, so it is
    /// also the one that must not suggest reopening.
    case registrationRepairStalled(String)
}

/// A cause plus what the user should be told about side effects.
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
