// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Issues and *keeps* a session's live automation grant once it is
/// terminal-bound: the recoverable grant-pending lifecycle for an automation
/// tab.
///
/// A one-shot "grant after bind" is not enough: a transient validation outage
/// (the validated-GUI signature walk momentarily can't complete → `notReady`)
/// or a connection blip can fail the initial grant, and if that outage outlasts
/// the bind poll loop the tab would sit permanently ungranted until an unrelated
/// reconnect. So a failed grant is *retried* with a fresh revision and backoff
/// until it applies, or until a terminal outcome (the session is gone, or the
/// peer isn't the validated GUI) makes retrying pointless.
///
/// Owned per-tab by `TabContentViewController` and driven from the terminal
/// bind-success path: `sessionBound` fires on the initial bind and on every
/// reconnect rebind, so a reconnect (which loses the daemon's in-memory grant
/// store) reissues automatically under the fresh connection epoch. The lifecycle
/// is unit-testable in isolation (inject the client + sleep); the VC glue that
/// calls it is thin.
@MainActor
final class AutomationGrantCoordinator {
    private let client: any AutomationGranting
    private let baseBackoffNanos: UInt64
    private let maxBackoffNanos: UInt64
    /// Injectable delay; returns `false` if cancelled during the wait. Tests
    /// pass a no-delay stub so retries run without real time.
    private let sleep: (UInt64) async -> Bool
    /// In-flight retry loops, keyed by session. A per-session generation lets a
    /// superseding `sessionBound` (a reconnect rebind) cancel-and-replace the
    /// loop without the old loop's cleanup clobbering the new one. Both maps
    /// hold ONLY sessions with an active loop: an entry is cleared when the
    /// loop completes or is invalidated, so neither accumulates tombstones.
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var generation: [UUID: Int] = [:]
    /// A single monotonic source for generation stamps. Global (not per-session)
    /// so a stamp is never reused: a stale frame's generation can never
    /// coincidentally match a newer loop's, even after the per-session entry was
    /// cleared and the session re-bound.
    private var nextGeneration = 0

    /// Test seam: sessions with a retry loop still in flight.
    var pendingSessionsForTesting: Set<UUID> { Set(tasks.keys) }

    /// Test seam: number of retained per-session generation entries. Must track
    /// `pendingSessionsForTesting.count`: a nonzero value with no pending loop
    /// would be a leaked tombstone.
    var generationEntryCountForTesting: Int { generation.count }

    init(
        client: any AutomationGranting,
        baseBackoffNanos: UInt64 = 200_000_000,
        maxBackoffNanos: UInt64 = 5_000_000_000,
        sleep: @escaping (UInt64) async -> Bool = { nanos in
            do { try await Task.sleep(nanoseconds: nanos); return true } catch { return false }
        }
    ) {
        self.client = client
        self.baseBackoffNanos = baseBackoffNanos
        self.maxBackoffNanos = maxBackoffNanos
        self.sleep = sleep
    }

    /// A grant failure worth retrying: a transport drop, or the retryable
    /// `notReady` (-32002) the validated-GUI scope check returns when the peer's
    /// signature couldn't be resolved this time. Everything else, a dead
    /// session (`invalidParams`), a stable `scope_violation`, a decode error, is
    /// terminal.
    private static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case DaemonClientError.transport:
            return true

        case let DaemonClientError.daemon(code, _):
            return code == -32_002  // notReady: validation temporarily unavailable

        default:
            return false
        }
    }

    /// The automation tab's session is now terminal-bound (initial bind or a
    /// reconnect rebind): (re)issue its grant, retrying transient failures until
    /// it applies. A non-automation role is a no-op: no grant, so its in-tab
    /// CLI never reaches the cross-tab verbs. Re-calling supersedes any in-flight
    /// attempt for the same session.
    func sessionBound(role: SessionRole, sessionId: String) {
        guard role == .automation, let uuid = UUID(uuidString: sessionId) else { return }
        tasks[uuid]?.cancel()
        nextGeneration += 1
        let gen = nextGeneration
        generation[uuid] = gen
        tasks[uuid] = Task { [weak self] in await self?.grantWithRetry(uuid, generation: gen) }
    }

    /// The session's terminal or tab was removed: stop retrying its grant. Wakes
    /// a sleeping backoff immediately (cancel) AND clears the loop's generation,
    /// so no FUTURE retry regrants a session the GUI is tearing down.
    ///
    /// This is client-side only: it cannot stop a grant already executing
    /// inside the daemon. Per the G4 rule, an in-flight grant may finish; it is
    /// then revoked authoritatively by `session.close` (the store's
    /// session-removal fence) or by the GUI's next omitting inventory
    /// reconciliation. Cancelling here just stops us from *re-sending* a grant
    /// for a session that's going away (e.g. briefly regranting a still-live
    /// daemon ghost, were a `session.close` lost). Idempotent for an untracked
    /// session.
    func sessionRemoved(sessionId: String) {
        guard let uuid = UUID(uuidString: sessionId) else { return }
        invalidate(uuid)
    }

    /// Cancel every in-flight retry loop: tab teardown and the `deinit`
    /// fallback. During a persistent outage the coordinator retains its retry
    /// `Task` (in `tasks`) while the running frame retains the coordinator (it
    /// holds `self`), a cycle that keeps the coordinator alive until the loop
    /// ends. (The owning `TabContentViewController` is unaffected: the bind
    /// closure captures it weakly and the coordinator never references it back,
    /// so it deallocates independently.) Cancelling breaks the cycle so the
    /// coordinator can deallocate promptly rather than lingering on the outage.
    func cancelAll() {
        for uuid in Array(tasks.keys) { invalidate(uuid) }
    }

    /// Drop + cancel a single session's loop. Clearing the generation entry (a)
    /// leaves no tombstone and (b) makes a frame that resumes after this bail at
    /// its next `generation[sid] == gen` check (a global monotonic stamp is
    /// never reissued, so the cleared entry can't accidentally re-match); the
    /// `cancel()` wakes a parked backoff so it bails now rather than after the
    /// delay. Untracked session → both removals are no-ops; nothing is stored.
    private func invalidate(_ uuid: UUID) {
        generation.removeValue(forKey: uuid)
        tasks.removeValue(forKey: uuid)?.cancel()
    }

    private func grantWithRetry(_ sessionId: UUID, generation gen: Int) async {
        // On completion, clear this session's task + generation IFF this frame
        // is still the current one (a superseding `sessionBound` or an
        // `invalidate` owns/cleared them otherwise). Keeps both maps holding
        // only live loops: no tombstone accumulation.
        defer {
            if generation[sessionId] == gen {
                tasks[sessionId] = nil
                generation[sessionId] = nil
            }
        }
        var backoff = baseBackoffNanos
        while !Task.isCancelled, generation[sessionId] == gen {
            do {
                let result = try await client.grantAutomation(sessionIds: [sessionId])
                if !result.applied {
                    // A higher `(epoch, revision)` already decided this session's
                    // grant: a reconnected connection with a newer epoch owns
                    // the reissue. Retrying can't win against a higher epoch, so
                    // stop.
                    FileHandle.standardError.write(
                        Data("deviceterm: automation grant superseded by a newer connection\n".utf8)
                    )
                }
                return
            } catch is CancellationError {
                // The loop was cancelled (tab/terminal removed) while a request
                // was in flight, now propagated instead of swallowed. Exit
                // quietly; this is a clean stop, not a failure.
                return
            } catch let error where Self.isRetryable(error) {
                // Transient: a connection blip or a `notReady` validation flake.
                // Back off and retry with a FRESH revision (the client stamps
                // it), so an outage lasting beyond the bind loop still recovers
                // without waiting for an unrelated reconnect.
                if !(await sleep(backoff)) { return }  // cancelled during backoff
                backoff = min(backoff * 2, maxBackoffNanos)
            } catch {
                // Terminal: the session is gone (`invalidParams`) or the peer
                // failed validation (`scope_violation`). Retrying is pointless:
                // fail closed (no grant, verbs unavailable) and stop.
                FileHandle.standardError.write(
                    Data("deviceterm: automation grant failed permanently: \(error)\n".utf8)
                )
                return
            }
        }
    }
}
