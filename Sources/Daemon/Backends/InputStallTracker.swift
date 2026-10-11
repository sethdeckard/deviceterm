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
        /// that missed their wait during it.
        case ended(operation: String, duration: Duration, timeouts: Int)
    }

    private var stalledSince: ContinuousClock.Instant?
    private var timeouts = 0

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
        episodes += 1
        return .began(operation: operation)
    }

    /// Record a send that completed in time.
    mutating func noteCompleted(
        operation: String,
        at now: ContinuousClock.Instant
    ) -> Transition? {
        guard let since = stalledSince else { return nil }
        stalledSince = nil
        return .ended(operation: operation, duration: now - since, timeouts: timeouts)
    }
}
