// SPDX-License-Identifier: GPL-3.0-or-later
//
// PeerVerdictCache: a bounded, daemon-wide cache of GUI-peer
// validation verdicts keyed by stable audit-token identity.
//
// `DispatchPeerContext.validatedGUIPeer` is stamped on every XPC
// dispatch, so a local process could otherwise force the expensive
// `SecCode` signature walk (`PeerIdentity.validateGUIPeer`) by opening
// a connection, dispatching once, closing, and repeating. Caching the
// verdict keyed by the peer's `(pid, pidversion)` collapses that: a
// connection reuses the verdict while its identity remains resident, so
// churn from one process doesn't re-walk. A miss re-runs the walk after
// a new execution identity (a fresh `pidversion`, e.g. after exec),
// eviction, or an earlier `.ephemeral` (non-cached) result.
//
// Two design points address availability and fairness:
//
//   - Only STABLE verdicts are cached (`.cache`): a positive result, or
//     a genuine signature mismatch. A NON-CACHEABLE result (`.ephemeral`,
//     the peer's identity couldn't be read) is returned but not
//     stored, so a legitimate GUI whose validation failed once isn't
//     pinned to a cached `false`.
//   - The signature walk runs in a detached task, NOT inside this
//     actor's critical section. The actor only does O(1) map work
//     before suspending on the in-flight task, so unrelated peers with
//     different keys don't serialize behind one walk: same-key callers
//     still dedup onto the one in-flight task.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

actor PeerVerdictCache {
    /// Stable identity of a peer process: pid plus the pid-generation
    /// counter (`pidversion`). Two live processes never share a pid, and
    /// `pidversion` disambiguates pid reuse over time. Read via the
    /// documented libbsm accessors: the token layout is opaque.
    struct Key: Hashable, Sendable {
        let pid: pid_t
        let pidVersion: Int32

        init(auditToken token: audit_token_t) {
            self.pid = audit_token_to_pid(token)
            self.pidVersion = audit_token_to_pidversion(token)
        }
    }

    /// The classification of a `resolve()` outcome. `.cache` is stable
    /// and stored; `.ephemeral` is non-cacheable and returned without
    /// storing (so it's retried on the next lookup).
    enum Resolution: Sendable {
        case cache(Bool)
        case ephemeral(Bool)

        var verdict: Bool {
            switch self {
            case let .cache(value), let .ephemeral(value):
                return value
            }
        }

        var isStable: Bool {
            if case .cache = self { return true }
            return false
        }
    }

    /// The result of a lookup: the verdict, plus whether it was stable
    /// (so the caller can decide to hold its own per-connection copy).
    struct Outcome: Sendable {
        let verdict: Bool
        let stable: Bool
    }

    private let capacity: Int
    private var verdicts: [Key: Bool] = [:]
    /// FIFO eviction order, oldest first. A verdict is stable for a
    /// process's lifetime, so simple FIFO (not LRU) is sufficient.
    private var order: [Key] = []
    /// In-flight resolutions, so concurrent same-key lookups share one
    /// walk instead of each starting their own.
    private var inFlight: [Key: Task<Resolution, Never>] = [:]

    /// Cached count (for tests/introspection).
    var count: Int { verdicts.count }

    init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    /// Return the cached verdict for `key`, or resolve it. `resolve`
    /// runs the signature walk in a **detached** task, so it executes
    /// off this actor and unrelated peers aren't blocked behind it;
    /// concurrent lookups for the same key await the one in-flight task.
    /// Only `.cache` resolutions are stored.
    func verdict(
        for key: Key,
        resolve: @escaping @Sendable () -> Resolution
    ) async -> Outcome {
        if let cached = verdicts[key] {
            return Outcome(verdict: cached, stable: true)
        }
        if let existing = inFlight[key] {
            let resolution = await existing.value
            return Outcome(verdict: resolution.verdict, stable: resolution.isStable)
        }
        // Detached so the synchronous Security-framework walk runs off
        // this actor's executor. Assigning `inFlight` before the first
        // suspension means a concurrent same-key caller finds this task.
        let task = Task.detached { resolve() }
        inFlight[key] = task
        let resolution = await task.value
        inFlight[key] = nil
        if case let .cache(value) = resolution {
            store(key: key, verdict: value)
        }
        return Outcome(verdict: resolution.verdict, stable: resolution.isStable)
    }

    private func store(key: Key, verdict: Bool) {
        verdicts[key] = verdict
        order.append(key)
        if order.count > capacity {
            let evicted = order.removeFirst()
            verdicts.removeValue(forKey: evicted)
        }
    }
}
