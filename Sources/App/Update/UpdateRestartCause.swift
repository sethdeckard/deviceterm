// SPDX-License-Identifier: GPL-3.0-or-later

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
