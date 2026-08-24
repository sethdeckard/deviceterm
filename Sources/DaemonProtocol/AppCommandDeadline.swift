// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How long a back-channel command stays live, and the clock the daemon
/// and GUI both read to decide.
///
/// A published `AppCommand` can outlive the caller that asked for it.
/// Both hops buffer unbounded (the daemon's `AsyncStream`, then the
/// GUI's), so a frame can remain queued past its reply deadline and be
/// drained long afterwards, potentially after the caller has received an
/// error. The daemon cannot unsend a buffered frame; only the consumer
/// can decline to act on it. That is what
/// `AppCommand.expiresAtMonotonicNanos` is for, and this is the shared
/// vocabulary both sides stamp and check it against.
///
/// The two timeouts must not converge, so they live here together rather
/// than as a literal at each call site, where that ordering would not be
/// checkable by a test.
public enum AppCommandDeadline {
    /// How long the daemon waits for the GUI to answer an `AppCommand`
    /// before failing the caller with `intent.guiUnavailable`.
    ///
    /// Held strictly under `cliRequestTimeoutSeconds`. The CLI's
    /// response deadline starts before the daemon begins handling and
    /// publishing the request, so an equal budget lets the CLI's
    /// deadline win and the caller sees `timed out waiting for daemon
    /// response` with no indication of why. Keeping this below the CLI's
    /// default reserves time to return `intent.guiUnavailable` before
    /// the transport deadline. It reserves that time rather than
    /// guaranteeing it: earlier queueing and return-path latency both
    /// eat the margin.
    public static let guiReplyTimeoutMs: Int = 4_000

    /// Default response timeout for ordinary CLI RPCs. Some operations
    /// override it, notably gesture requests, which add the gesture's
    /// own wall-clock. It is the ceiling the daemon's GUI-reply timeout
    /// stays under, and it is not raised to make room for a slower
    /// GUI.
    public static let cliRequestTimeoutSeconds: Double = 5

    /// Wire code the GUI acks with when it declines an expired command.
    ///
    /// Usually diagnostic: the daemon has generally dropped its pending
    /// record by the time this is sent, so the ack lands nowhere and is
    /// logged rather than surfaced. Expiry is only a clock comparison,
    /// though, and the daemon's timeout task is scheduled separately, so
    /// this can arrive first and resume the caller with this code. Either
    /// way it keeps "declined, expired" distinguishable from "dispatched
    /// and failed".
    public static let expiredCode = "intent.commandExpired"

    /// Current reading of the host's monotonic clock, in nanoseconds.
    ///
    /// `CLOCK_MONOTONIC_RAW` is system-wide and unaffected by NTP or a
    /// user changing the clock, so a value the daemon stamps is directly
    /// comparable in the GUI process. A wall-clock `Date` would not be:
    /// an adjustment between publish and drain could expire a live
    /// command or revive a dead one.
    public static func nowMonotonicNanos() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    }

    /// The monotonic instant `timeoutMs` from now, for stamping onto a
    /// command at publish time.
    public static func expiry(inMs timeoutMs: Int) -> UInt64 {
        nowMonotonicNanos() &+ UInt64(max(0, timeoutMs)) &* 1_000_000
    }
}
