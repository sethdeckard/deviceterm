// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif

// PeerVerdictCache: the churn mitigation. Stable verdicts dedup by peer
// process identity `(pid, pidversion)` while resident; a non-cacheable
// (`.ephemeral`) result is not stored, so it's retried on the next
// lookup; pid reuse (a new `pidversion`) is a distinct key; the bounded
// capacity evicts oldest-first; and same-key lookups share one walk.

/// A `@Sendable` counter for how many times `resolve` ran.
private final class ResolveCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}

/// Build an audit token with a given pid and pidversion. The cache keys
/// via the libbsm accessors, which read these back.
private func token(pid: pid_t, pidVersion: Int32) -> audit_token_t {
    audit_token_t(val: (0, 0, 0, 0, 0, UInt32(bitPattern: pid), 0, UInt32(bitPattern: pidVersion)))
}

@Test
func sameIdentityResolvesOnceWhileResident() async {
    let cache = PeerVerdictCache()
    let counter = ResolveCounter()
    let key = PeerVerdictCache.Key(auditToken: token(pid: 42, pidVersion: 7))
    let first = await cache.verdict(for: key) { counter.bump(); return .cache(true) }
    let second = await cache.verdict(for: key) { counter.bump(); return .cache(true) }
    #expect(first.verdict)
    #expect(first.stable)
    #expect(second.verdict)
    #expect(counter.value == 1)
}

@Test
func distinctPidsEachResolve() async {
    let cache = PeerVerdictCache()
    let counter = ResolveCounter()
    _ = await cache.verdict(for: .init(auditToken: token(pid: 1, pidVersion: 1))) {
        counter.bump(); return .cache(true)
    }
    _ = await cache.verdict(for: .init(auditToken: token(pid: 2, pidVersion: 1))) {
        counter.bump(); return .cache(false)
    }
    #expect(counter.value == 2)
}

@Test
func pidReuseIsADistinctKey() async {
    // Same pid, different pidversion (the process was recycled) ⇒ the
    // old `true` verdict must not leak; the resolver runs again.
    let cache = PeerVerdictCache()
    let counter = ResolveCounter()
    let reused = await cache.verdict(
        for: .init(auditToken: token(pid: 100, pidVersion: 1))
    ) { counter.bump(); return .cache(true) }
    let fresh = await cache.verdict(
        for: .init(auditToken: token(pid: 100, pidVersion: 2))
    ) { counter.bump(); return .cache(false) }
    #expect(reused.verdict)
    #expect(!fresh.verdict)
    #expect(counter.value == 2)
}

@Test
func ephemeralResultIsNotCached() async {
    // A non-cacheable result is returned but not stored, so it's retried
    // on the next lookup: a legitimate peer isn't pinned to it.
    let cache = PeerVerdictCache()
    let counter = ResolveCounter()
    let key = PeerVerdictCache.Key(auditToken: token(pid: 7, pidVersion: 1))
    let first = await cache.verdict(for: key) { counter.bump(); return .ephemeral(false) }
    let second = await cache.verdict(for: key) { counter.bump(); return .cache(true) }
    #expect(!first.verdict)
    #expect(!first.stable)
    #expect(second.verdict)
    #expect(counter.value == 2)
    #expect(await cache.count == 1)  // only the stable second result stored
}

@Test
func capacityEvictsOldest() async {
    let cache = PeerVerdictCache(capacity: 2)
    let counter = ResolveCounter()
    let keys = (1...3).map { PeerVerdictCache.Key(auditToken: token(pid: pid_t($0), pidVersion: 1)) }
    for key in keys {
        _ = await cache.verdict(for: key) { counter.bump(); return .cache(true) }
    }
    #expect(counter.value == 3)
    #expect(await cache.count == 2)
    // The first key was evicted, so querying it resolves again.
    _ = await cache.verdict(for: keys[0]) { counter.bump(); return .cache(true) }
    #expect(counter.value == 4)
}

@Test
func concurrentSameKeyLookupsShareOneWalk() async {
    // Many concurrent lookups for one identity must run the walk once:
    // the in-flight task dedups them rather than each re-walking.
    let cache = PeerVerdictCache()
    let counter = ResolveCounter()
    let key = PeerVerdictCache.Key(auditToken: token(pid: 55, pidVersion: 1))
    await withTaskGroup(of: Bool.self) { group in
        for _ in 0..<8 {
            group.addTask {
                await cache.verdict(for: key) {
                    counter.bump()
                    // Widen the window so the lookups overlap on the
                    // in-flight task rather than the cached path.
                    Thread.sleep(forTimeInterval: 0.03)
                    return .cache(true)
                }.verdict
            }
        }
        for await verdict in group { #expect(verdict) }
    }
    #expect(counter.value == 1)
}
