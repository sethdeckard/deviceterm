// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A serial FIFO worker for one channel.
///
/// A Swift actor does not, on its own, serialise a multi-step operation: each
/// `await` is a suspension point where another call can interleave. This worker
/// is the fix. Submitted jobs run through a single draining task that awaits each
/// one *fully* before starting the next, so two operations enqueued on the same
/// channel can neither overtake nor interleave, even when one suspends partway
/// through a multi-report gesture. Independent channels get independent pumps and
/// so proceed concurrently.
final class ChannelPump: @unchecked Sendable {
    private let queue: AsyncStream<@Sendable () async -> Void>.Continuation
    private let worker: Task<Void, Never>

    init() {
        let (stream, continuation) = AsyncStream<@Sendable () async -> Void>.makeStream()
        self.queue = continuation
        self.worker = Task { for await job in stream { await job() } }
    }

    /// Enqueue `job` and await its result. Submission order is preserved, and the
    /// job runs to completion before the next one on this pump starts. Jobs
    /// already queued when `finish()` is called still drain; a job submitted
    /// *after* `finish()` is rejected with `CancellationError` rather than
    /// hanging (a finished stream never runs the job, so nothing would resume the
    /// continuation).
    func run<Value: Sendable>(_ job: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
            let outcome = queue.yield {
                do {
                    continuation.resume(returning: try await job())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            // A terminated stream drops the job (the worker won't run it, so it
            // can't resume the continuation), so fail here to let the caller return.
            if case .terminated = outcome {
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    /// Stop accepting new jobs. The worker ends after the running job and any
    /// already-queued jobs drain; jobs submitted after this throw
    /// `CancellationError` (see `run`).
    func finish() {
        queue.finish()
    }
}
