// SPDX-License-Identifier: GPL-3.0-or-later
//
// RecoveryHandshakeOutcome: what answered after a startup wire-version
// recovery asked the incompatible helper to stop.
//
// Deliberately four cases rather than a Bool, because "the versions still
// differ" is two different situations and only one of them is a verdict.
//
// `daemon.shutdown` acknowledges `DaemonMethods.shutdownAckGraceMs` before the
// daemon exits, and SIGKILL is accepted before teardown finishes, so on the
// SUCCESSFUL path the old helper may answer at least one more ping with the old
// wire version. Reading that as "recovery failed" would abandon the happy path;
// reading it as "keep waiting" is what lets the replacement come up. That is why
// the pid is classified before the version: a reply carrying the pinned pid is
// treated as the stop not having taken effect yet, and says nothing about
// compatibility. Only the number is compared, and a pid can be reused.
//
// A reply from a DIFFERENT process is the opposite: the helper was replaced and
// the replacement still disagrees, which no amount of further stopping fixes.
// Signalling that one would only make launchd start another exactly like it.

enum RecoveryHandshakeOutcome: Sendable, Equatable {
    /// The wire versions match. Recovery is done and the transport can return
    /// to full service.
    case compatible
    /// A reply carrying the pinned pid, treated as the old helper still
    /// answering. Only the number is compared, and a pid can be reused, so this
    /// reports progress rather than identity: the stop has not taken effect yet.
    case sameHelperStillAnswering(pid: Int32)
    /// A different process answered, and it still speaks a different wire
    /// version. Decisive: the registration resolves to a helper that does not
    /// match this build, so stopping it again would not converge.
    case incompatible(daemonVersion: String, pid: Int32)
    /// Nothing answered within the bound, carrying the transport's own words.
    /// Either the replacement has not come up yet or nothing will, and a single
    /// unanswered ping cannot tell those apart.
    case unreachable(String)
}
