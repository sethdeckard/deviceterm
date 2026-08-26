// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Keeps the daemon's copy of one tab's live label in step with the GUI.
///
/// The published value is `TabTitleViewModel.publishableTitle`: the tab's
/// label in its normalized, bounded form, and nil whenever the label would
/// only restate the session name the daemon already holds (or the GUI's
/// generic fallback). It goes under the tab's PRIMARY terminal session,
/// because `tabs.list` is per-session while a title is per-tab. A split
/// tab's other sessions carry no title.
///
/// Three properties the naive "call the daemon from the observation" shape
/// gets wrong, and why this type exists:
///
///   - **Coalescing.** A shell can emit a burst of OSC title updates while
///     redrawing a prompt. Each pass waits a short FIXED window and then
///     sends the LATEST value, so a burst costs one RPC and continuous
///     churn still flushes every window rather than being postponed
///     forever.
///   - **Ordering.** There is one desired value and at most one send in
///     flight, so an older update can never land after a newer one. No
///     per-push sequence number needed. A value that changes mid-send is
///     simply what the next pass sends.
///   - **Lifecycle.** A queued push is dropped when the tab tears down
///     (`cancel`), and a push rejected because its session is gone is
///     abandoned rather than retried forever. When the primary terminal of
///     a split tab closes, the tab's representative session changes; the
///     caller re-reports under the new session and the old session's cached
///     title dies with the session daemon-side.
///
/// A reconnect is the one case where an UNCHANGED title must be re-sent:
/// the daemon's cache is memory-only, so a daemon restart or connection
/// replacement leaves it empty while the GUI, seeing no change, would never
/// push again, so `tabs.list` would report the session name until the next
/// OSC event, which may never come. `republish()` forgets what was sent and
/// pushes the current value. Its caller must fire it only after the
/// session inventory has been re-supplied, since the daemon rejects a title
/// for a session it doesn't hold.
@MainActor
final class DisplayTitlePublisher {
    /// Injected seams so the loop is testable without a live daemon.
    struct Dependencies {
        /// Push one title. The lone `session.setDisplayTitle` call site.
        var send: @MainActor (String, String?) async throws -> Void
        /// Cancellation-aware sleep; false means cancelled (the loop exits).
        var sleep: (UInt64) async -> Bool = { nanos in
            do { try await Task.sleep(nanoseconds: nanos); return true } catch { return false }
        }
        /// Fixed coalescing window before each send (ns). Being fixed rather
        /// than reset on each change means a shell redrawing continuously
        /// still gets a push every window.
        var coalesceWindowNanos: UInt64 = 150_000_000
        var baseBackoffNanos: UInt64 = 200_000_000
        var maxBackoffNanos: UInt64 = 5_000_000_000
    }

    private struct Push: Equatable {
        let sessionId: String
        let title: String?
    }

    /// `-32011` scope violation: the peer isn't the validated GUI. Two ways
    /// to be here, and both are stable for the life of the process: the
    /// `--smoke` UDS fallback, which carries no audit token at all, and an
    /// XPC peer whose signature check came back a stable mismatch (an
    /// ephemeral verdict gets its own retryable code instead). Neither can
    /// change while the app runs, so stop for good rather than earning a
    /// refusal for every title the shell emits.
    private static let permanentRefusalCode = -32_011
    /// `-32601` method not found: a daemon predating the method, which a
    /// stale helper surviving an app update can be. Retrying that daemon is
    /// pointless, but the *next* one may well support it: an idle exit or a
    /// crash replaces the helper without the GUI restarting. So this stop
    /// is scoped to the connection and `republish()` re-arms it. Re-arming
    /// on reconnect (not on a timer, and not per push) is what keeps it from
    /// becoming a refusal loop: one refused push per connection, at most.
    private static let connectionRefusalCode = -32_601
    /// Definite per-target rejections: the session is unknown (-32001) or the
    /// request was malformed (-32602). Neither improves on retry, but neither
    /// says anything about the NEXT title for a different session, so the
    /// publisher abandons just this value and keeps running.
    private static let definiteRejectionCodes: Set<Int> = [-32_001, -32_602]

    private let deps: Dependencies
    private var desired: Push?
    private var lastSent: Push?
    /// Bumped by `republish()`. A send in flight when a republish lands
    /// must not write `lastSent` on resumption. Doing so would clobber the
    /// forget and settle the loop with nothing pending, silently dropping
    /// the re-push until the next title CHANGE, which is exactly the event
    /// republish exists to not depend on.
    private var republishGeneration = 0
    private var running = false
    /// Given up for the life of the app: smoke mode, or the tab tore down.
    private var stoppedPermanently = false
    /// Given up for this connection only; cleared by `republish()`.
    private var stoppedForConnection = false
    private var stopped: Bool { stoppedPermanently || stoppedForConnection }
    private var loop: Task<Void, Never>?

    /// Test seam: no further work will happen unaided. Either the publisher
    /// has stopped, or nothing is queued and nothing is in flight. A stopped
    /// publisher counts as settled even with a value still pending: that
    /// value is exactly what it refuses to send until something (a
    /// republish) re-arms it.
    var isSettledForTesting: Bool { stopped || (!running && pending == nil) }
    /// Test seam: the publisher has given up, for this connection or for good.
    var isStoppedForTesting: Bool { stopped }

    private var pending: Push? {
        guard let desired, desired != lastSent else { return nil }
        return desired
    }

    init(_ deps: Dependencies) {
        self.deps = deps
    }

    /// Report the tab's current label under its current primary session.
    /// Cheap and idempotent: the caller re-reports on every observation
    /// pass, and an unchanged value does nothing. An empty session id (a
    /// tab whose state has already been removed) is dropped rather than
    /// pushed as a bogus target.
    ///
    /// Only a *permanent* stop discards the value. While a connection-scoped
    /// stop is in effect the latest title is still recorded: `start()` won't
    /// send it, but the republish that re-arms the publisher must push what
    /// the tab reads now, not the title that was current when the refusal
    /// landed.
    func update(sessionId: String, title: String?) {
        guard !stoppedPermanently, !sessionId.isEmpty else { return }
        let push = Push(sessionId: sessionId, title: DisplayTitleNormalizer.normalize(title))
        guard push != desired else { return }
        desired = push
        start()
    }

    /// The connection was replaced, so the daemon's cache is empty: forget
    /// what was sent and push the current value again even though it hasn't
    /// changed. Also re-arms a connection-scoped stop, since the replacement
    /// daemon is a different daemon and the one that refused the method is
    /// gone.
    func republish() {
        guard !stoppedPermanently else { return }
        stoppedForConnection = false
        lastSent = nil
        republishGeneration += 1
        start()
    }

    /// The tab is tearing down: drop any QUEUED push and never send again.
    /// A push already suspended in `send` still completes, since nothing on
    /// that path is cancellation-aware, but it targets a closing session, so
    /// the daemon rejects it.
    func cancel() {
        stoppedPermanently = true
        loop?.cancel()
        loop = nil
    }

    private func start() {
        guard !running, !stopped, pending != nil else { return }
        running = true
        loop = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        defer { running = false }
        var backoff = deps.baseBackoffNanos
        while !stopped, pending != nil {
            if !(await deps.sleep(deps.coalesceWindowNanos)) { return }
            // Re-read after the window: this is what makes a burst collapse
            // into one send, and what lets a teardown during the wait win.
            guard !stopped, let target = pending else { return }
            // Read before the suspension: a republish landing mid-send makes
            // this send's outcome stale, so neither success nor a definite
            // rejection may record it as sent.
            let generation = republishGeneration
            do {
                try await deps.send(target.sessionId, target.title)
                markSent(target, generation: generation)
                backoff = deps.baseBackoffNanos
            } catch let DaemonClientError.daemon(code, _)
                where code == Self.permanentRefusalCode {
                stoppedPermanently = true
                return
            } catch let DaemonClientError.daemon(code, _)
                where code == Self.connectionRefusalCode {
                // Same staleness rule as `markSent`: a republish landing
                // mid-send means this refusal came from a connection the
                // client has already replaced. Honoring it would disable
                // the REPLACEMENT, which may well support the method, and
                // strand the pending title. Retry on the new one.
                guard generation == republishGeneration else { continue }
                stoppedForConnection = true
                return
            } catch let DaemonClientError.daemon(code, _)
                where Self.definiteRejectionCodes.contains(code) {
                // Abandon this value: marking it sent stops the retry without
                // blocking a later push for a different session or title.
                markSent(target, generation: generation)
            } catch {
                // Transport drop or an unclassified daemon error: keep the
                // value pending and retry with capped backoff.
                if !(await deps.sleep(backoff)) { return }
                backoff = min(backoff * 2, deps.maxBackoffNanos)
            }
        }
    }

    /// Record a completed send, unless a republish superseded it while it
    /// was in flight, in which case the value stays pending and the loop
    /// sends it again.
    private func markSent(_ target: Push, generation: Int) {
        guard generation == republishGeneration else { return }
        lastSent = target
    }
}
