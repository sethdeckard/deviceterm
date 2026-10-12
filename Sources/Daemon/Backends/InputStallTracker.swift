// SPDX-License-Identifier: GPL-3.0-or-later

/// Whether a simulator's HID sends are completing, folded into stall episodes.
///
/// A timeout means the completion callback missed the bridge's one-second
/// deadline. The send is not cancelled and may complete later; delivery is
/// unknown. So a timeout marks the transport as stalled, and the stall ends at
/// the next send that completes in time. Only the edges are reported, because
/// a stalled pane under a held finger times out once a second for as long as
/// the stall lasts.
struct InputStallTracker: Equatable {
    /// One edge of a stall.
    enum Transition: Equatable, Sendable {
        /// The first send to time out since sends were last completing.
        case began(operation: String)
        /// A send completed in time after a stall. `timeouts` counts the sends
        /// that missed their wait during it, and `refused` the ones the bridge
        /// declined to send because an earlier one hadn't completed.
        case ended(operation: String, duration: Duration, timeouts: Int, refused: Int)
    }

    private var stalledSince: ContinuousClock.Instant?
    private var timeouts = 0
    private var refused = 0
    /// Bumped by every timeout, so a drain observed for an older one can't
    /// end a refusal a newer timeout started.
    private var drainToken: UInt64 = 0

    /// Whether the bridge is refusing input now: a send timed out and the
    /// client hasn't drained since.
    ///
    /// Kept apart from the logged stall, which ends at the next send that
    /// completes in time. A pane nobody touches sends nothing, so that end
    /// could be a long way off, while the refusal ends when the guest takes
    /// what was queued.
    private(set) var isRefusing = false

    /// Stall episodes over this tracker's life.
    private(set) var episodes = 0

    var isStalled: Bool { stalledSince != nil }

    /// Record a send that missed its completion wait.
    mutating func noteTimeout(
        operation: String,
        at now: ContinuousClock.Instant
    ) -> Transition? {
        timeouts += 1
        guard stalledSince == nil else { return nil }
        stalledSince = now
        timeouts = 1
        refused = 0
        episodes += 1
        return .began(operation: operation)
    }

    /// Mark the bridge as refusing after a timeout. Returns the token the
    /// matching drain has to present, and whether this began the refusal.
    mutating func beginRefusing() -> (token: UInt64, began: Bool) {
        drainToken &+= 1
        let began = !isRefusing
        isRefusing = true
        return (drainToken, began)
    }

    /// The client's sends drained. Ends the refusal if no timeout has come
    /// since the one that issued `token`, and reports whether it did.
    mutating func noteDrained(token: UInt64) -> Bool {
        guard isRefusing, token == drainToken else { return false }
        isRefusing = false
        return true
    }

    /// Record a send the bridge refused because an earlier one hadn't
    /// completed. Counted only inside a stall, which is the only time the
    /// bridge has anything outstanding to refuse behind.
    mutating func noteRefused() {
        guard stalledSince != nil else { return }
        refused += 1
    }

    /// Record a send that completed in time.
    mutating func noteCompleted(
        operation: String,
        at now: ContinuousClock.Instant
    ) -> Transition? {
        guard let since = stalledSince else { return nil }
        stalledSince = nil
        return .ended(operation: operation, duration: now - since, timeouts: timeouts, refused: refused)
    }
}
