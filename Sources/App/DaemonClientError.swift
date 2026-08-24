// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

enum DaemonClientError: Error, CustomStringConvertible {
    case transport(String)
    case daemon(
        code:
        Int,
        message: String
        )
    case versionMismatch(
        client:
        String,
        daemon: String
        )
    case decode(String)
    /// `daemon.shutdown` returned without a `{ok: true}` ack: the
    /// incompatible daemon did not confirm it is terminating.
    case shutdownNotAcknowledged
    /// `daemon.shutdown` was sent but no reply arrived within the bound: a
    /// daemon that answers `ping` but never acks shutdown must not stall
    /// startup/reconnect. The daemon's state is unknown (indeterminate).
    case shutdownTimedOut
    /// The call went out and no answer came back within its bound.
    ///
    /// The wait was abandoned, not the work: nothing cancels the daemon's
    /// handler, so the call may still complete on its side. What happens to
    /// that late reply depends on which bound raised this.
    ///
    /// For an ordinary request the transport was cancelled and the reply is
    /// discarded. A mutation bounded that way still has an unknown outcome,
    /// but none of those calls return a one-time identity, so nothing is lost
    /// that the GUI would need to name what it may have changed.
    ///
    /// The calls that *do* return one are bounded by their own caller through
    /// `Deadline.wait`, which lets the call finish and reconciles what it
    /// produced: `createSession` attempts to close a session no tab ever
    /// received, and `Router.runAttach` attempts to detach a pane no window is
    /// showing. Both are best-effort. Without that,
    /// a `session.create` reply would strand a session nobody can name (its
    /// capability leaves the daemon exactly once, and it survives an omitting
    /// `session.restoreBatch` on the same connection, since a live create's
    /// assertion deliberately outranks a restore baseline at that epoch), and
    /// an attach reply would strand a pane holding its device, and for a
    /// physical device its tunnel.
    case timedOut(method: String)

    var description: String {
        switch self {
        case let .transport(detail):
            return "transport error: \(detail)"

        case let .daemon(code, message):
            return "daemon error \(code): \(message)"

        case let .versionMismatch(client, daemon):
            return "daemon wire version \(daemon) != client \(client)"

        case let .decode(detail):
            return "decode error: \(detail)"

        case .shutdownNotAcknowledged:
            return "daemon.shutdown was not acknowledged"

        case .shutdownTimedOut:
            return "daemon.shutdown timed out awaiting acknowledgement"

        case let .timedOut(method):
            return "timed out: the deviceterm helper did not answer \(method)"
        }
    }

    var isVersionMismatch: Bool {
        if case .versionMismatch = self { return true }
        return false
    }

    /// True for startup failures that can occur before any helper reply has
    /// established reachability.
    ///
    /// A reply of any kind, including an error reply or a version mismatch,
    /// proves a helper process is running and therefore that its launchd
    /// registration resolves. The shutdown errors follow a successful ping, so
    /// reachability is already established; only `shutdownTimedOut` represents
    /// an unanswered shutdown call. Enumerated rather than defaulted so a new
    /// case has to declare which side it falls on.
    var isHelperUnreachable: Bool {
        switch self {
        case .transport, .timedOut:
            return true

        case .daemon, .versionMismatch, .decode, .shutdownNotAcknowledged, .shutdownTimedOut:
            return false
        }
    }
}
