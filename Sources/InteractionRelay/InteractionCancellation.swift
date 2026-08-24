// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A cancellation signal that reaches work already handed to a `ChannelPump`.
///
/// Cancelling the task that submitted a job does not cancel the job.
/// `ChannelPump.run` parks a continuation and yields the work to a separate
/// long-lived worker, so `Task.isCancelled` inside the job reads the worker's
/// state rather than the submitter's, and a queued job runs even after its
/// caller is gone. Per-job cancellation on the pump itself would put every
/// channel's FIFO ordering at risk to serve one verb, so the signal rides the
/// intent instead.
///
/// Isolated by a documented serial queue: it is read from the worker and
/// written from whichever task abandons the request.
package final class InteractionCancellation: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.deviceterm.relay.cancellation")
    private var cancelled = false

    package var isCancelled: Bool {
        queue.sync { cancelled }
    }

    package init() {}

    /// Ask the job to stop. Idempotent.
    package func cancel() {
        queue.sync { cancelled = true }
    }
}
