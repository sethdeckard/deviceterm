// SPDX-License-Identifier: GPL-3.0-or-later

/// Ties a pending close prompt to the thing it is asking about, taking
/// the prompt down when that thing stops existing.
///
/// A window-modal sheet yields the main actor while it is up. That is
/// what keeps the daemon's command back-channel being serviced, and it
/// is also what lets a CLI caller in another tab close the very tab or
/// pane the sheet is asking about. The prompt callers re-read their
/// target after the answer comes back, so answering a stale sheet is a
/// no-op rather than a wrong mutation, but the sheet itself would sit
/// there asking a question that can no longer mean anything.
///
/// `isTargetAlive` is evaluated against current state as soon as
/// `start()` runs, and again whenever the `@Observable` state it reads
/// changes. Because the first pass reads the world rather than a delta,
/// a caller may safely defer `start()` past the presentation it is
/// watching: a removal that lands in that gap is seen by the first
/// evaluation.
///
/// `dismiss` is allowed to answer "not yet". A sheet that is still
/// animating in, or that AppKit has queued behind another sheet on the
/// same window, cannot be ended until its turn comes. The watch keeps
/// trying rather than standing down, because Observation re-fires only
/// when tracked state changes and a target that is already gone changes
/// nothing further.
@MainActor
final class CloseSheetLifetime {
    /// Take the prompt down. Returns whether the watch is done: `true`
    /// once the prompt is gone or there is nothing left to take down,
    /// `false` while it is still queued and has to be tried again.
    typealias Dismiss = @MainActor () -> Bool

    /// How long to wait before trying a refused dismissal again.
    ///
    /// The sheet ahead can stay up for as long as its reader likes, so
    /// this interval is what stands between a queued prompt and a hot
    /// loop on the main actor competing with AppKit's event handling.
    /// Nobody is waiting on it: the prompt it paces is not on screen
    /// yet, and the only visible effect is how soon after the sheet
    /// ahead is answered this one disappears.
    private static let retryInterval = Duration.milliseconds(50)

    private let isTargetAlive: @MainActor () -> Bool
    private let dismiss: Dismiss
    private var token: ObservationToken?
    /// The one in-flight retry, held so a second cannot start beside it.
    ///
    /// The observation re-fires on any change to the state
    /// `isTargetAlive` reads, which for a tab means unrelated tab
    /// mutations elsewhere in the workspace. Each re-entry would
    /// otherwise fork its own recurring chain while the target stayed
    /// absent, and nothing joins them back up, so a long-queued prompt
    /// would accumulate wakeups without bound.
    private var retry: Task<Void, Never>?
    private var isFinished = false

    init(
        isTargetAlive: @escaping @MainActor () -> Bool,
        dismiss: @escaping Dismiss
    ) {
        self.isTargetAlive = isTargetAlive
        self.dismiss = dismiss
    }

    /// Begin watching. Calling this more than once, or after `finish()`,
    /// does nothing.
    func start() {
        guard !isFinished, token == nil else { return }
        token = observe { [weak self] in
            guard let self else { return }
            // Evaluate before any early return. Observation tracks only
            // what a pass actually read, so short-circuiting ahead of
            // this call would stop watching the fields it skipped and
            // the watch would never fire again.
            let alive = self.isTargetAlive()
            guard !self.isFinished, !alive else { return }
            self.attemptDismissal()
        }
    }

    /// Stop watching, permanently. Idempotent, and safe to call from
    /// inside `dismiss`.
    func finish() {
        isFinished = true
        token?.cancel()
        token = nil
        retry?.cancel()
        retry = nil
    }

    /// Try to take the prompt down, retrying on a paced loop for as long
    /// as it is still on its way up.
    ///
    /// The retry stops when `finish()` runs, when this object is
    /// released, or when the target becomes live again (a re-admitted
    /// pane), which stands the retry down while leaving the watch armed
    /// for the next change.
    ///
    /// There is no attempt limit: a sheet ahead of this one can be left
    /// up indefinitely, and giving up after N tries would strand exactly
    /// the prompt this watch exists to take down. `retryInterval` is
    /// what keeps the wait from becoming a busy loop.
    private func attemptDismissal() {
        guard !isFinished, !isTargetAlive() else { return }
        if dismiss() {
            finish()
            return
        }
        scheduleRetry()
    }

    /// Queue the next attempt, at most one at a time.
    private func scheduleRetry() {
        guard !isFinished, retry == nil else { return }
        retry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.retryInterval)
            guard !Task.isCancelled, let self else { return }
            // Cleared before the attempt, so a refusal can queue the
            // next one rather than finding this slot still taken.
            self.retry = nil
            self.attemptDismissal()
        }
    }
}
