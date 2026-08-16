// SPDX-License-Identifier: GPL-3.0-or-later
//
// `DaemonClientError.isHelperUnreachable`: the classifier that decides whether a
// failed launch connection is worth re-registering the helper agent for. It
// separates failures that can occur before any reply establishes reachability,
// which are consistent with a launchd registration that cannot spawn, from ones
// that follow a reply and so prove the registration resolves.
//
// Every case is pinned in one direction or the other, so a new
// `DaemonClientError` case has to be classified deliberately rather than
// inheriting a default.

@testable import App
import Foundation
import Testing

struct DaemonClientReachabilityTests {
    /// Silence. Nothing on the other end produced a reply, which is what a job
    /// launchd fails to spawn looks like from the GUI. The `daemon.ping`
    /// timeout is the exact shape a wedged registration surfaces as.
    @Test("unreachable: no reply reached the client", arguments: [
        DaemonClientError.timedOut(method: "daemon.ping"),
        DaemonClientError.transport("connection invalidated")
    ])
    func classifiesSilenceAsUnreachable(error: DaemonClientError) {
        #expect(error.isHelperUnreachable)
    }

    /// These errors establish helper reachability, so they are not evidence of
    /// a registration-launch failure. The shutdown cases follow a successful
    /// ping; only `shutdownTimedOut` represents an unanswered shutdown call.
    @Test("reachable: the helper answered", arguments: [
        DaemonClientError.daemon(code: -32_001, message: "unauthorized"),
        DaemonClientError.versionMismatch(client: "3", daemon: "4"),
        DaemonClientError.decode("unexpected payload"),
        DaemonClientError.shutdownNotAcknowledged,
        DaemonClientError.shutdownTimedOut
    ])
    func classifiesRepliesAsReachable(error: DaemonClientError) {
        #expect(!error.isHelperUnreachable)
    }

    /// A version mismatch has its own shutdown-and-relaunch remediation, so it
    /// must not enter the registration-repair path.
    @Test
    func keepsVersionMismatchOutOfTheRepairPath() {
        let mismatch = DaemonClientError.versionMismatch(client: "3", daemon: "4")
        #expect(mismatch.isVersionMismatch)
        #expect(!mismatch.isHelperUnreachable)
    }

    /// The timeout text names the method that went unanswered. This is the
    /// string the launch-failure alert shows, and the repair path logs it as
    /// the reason it re-registered.
    @Test
    func namesTheUnansweredMethod() {
        let error = DaemonClientError.timedOut(method: "daemon.ping")
        #expect(error.description == "timed out: the deviceterm helper did not answer daemon.ping")
    }
}
