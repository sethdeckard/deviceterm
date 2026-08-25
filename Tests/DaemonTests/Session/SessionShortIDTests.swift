// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

// SessionManager × ShortID: pins the identifier-model contract:
// every `createSession` mints a unique short_id, collisions are retried
// against the live set, and a degenerate mint strategy surfaces
// `SessionError.shortIDExhausted` rather than spinning the actor.

@Test
func createSessionAssignsNonEmptyShortID() async throws {
    let manager = SessionManager()
    let state = try await manager.makeSessionState(label: nil)
    #expect(!state.shortId.isEmpty)
    #expect(ShortID.isWellFormed(state.shortId))
}

@Test
func createSessionNameIsNilByDefault() async throws {
    let manager = SessionManager()
    let state = try await manager.makeSessionState(label: nil)
    #expect(state.name == nil)
}

@Test
func createSessionAcceptsExplicitName() async throws {
    let manager = SessionManager()
    let state = try await manager.makeSessionState(label: nil, name: "feature-auth")
    #expect(state.name == "feature-auth")
}

@Test
func createSessionMintsUniqueShortIDsAcrossSiblings() async throws {
    let manager = SessionManager()
    var seen: Set<String> = []
    for _ in 0..<20 {
        let state = try await manager.makeSessionState(label: nil)
        let (inserted, _) = seen.insert(state.shortId).self
        // (inserted, _) is the canonical tuple; use it to check
        // uniqueness explicitly.
        _ = inserted
        #expect(!state.shortId.isEmpty)
    }
    #expect(seen.count == 20)
}

@Test
func mintStrategyRetriesOnCollision() async throws {
    // Stage the strategy to return "aaaaaa" twice (the second call
    // collides with the first session's id) and then "bbbbbb".
    // SessionManager must resolve to "bbbbbb" rather than crashing or
    // returning the collided value.
    let counter = AtomicCounter()
    let sequence = ["aaaaaa", "aaaaaa", "bbbbbb"]
    let manager = SessionManager(
        mintShortID: { @Sendable in
        let index = counter.incrementAndGet() - 1
        return sequence[min(index, sequence.count - 1)]
        }
        )
    let first = try await manager.makeSessionState(label: nil)
    let second = try await manager.makeSessionState(label: nil)
    #expect(first.shortId == "aaaaaa")
    #expect(second.shortId == "bbbbbb")
}

@Test
func mintStrategyExhaustionSurfacesAsError() async throws {
    // A degenerate strategy that always returns the same id should
    // succeed once (first slot) and then exhaust on the next mint.
    let manager = SessionManager(mintShortID: { @Sendable in "deadbeef" })
    let first = try await manager.makeSessionState(label: nil)
    #expect(first.shortId == "deadbeef")
    await #expect(throws: SessionError.shortIDExhausted) {
        _ = try await manager.makeSessionState(label: nil)
    }
}

@Test
func allSessionsCarriesShortIDAndName() async throws {
    let counter = AtomicCounter()
    let ids = ["aaaa01", "bbbb02", "cccc03"]
    let manager = SessionManager(
        mintShortID: { @Sendable in
        let index = counter.incrementAndGet() - 1
        return ids[min(index, ids.count - 1)]
        }
        )
    _ = try await manager.makeSessionState(label: "alpha", name: "first")
    _ = try await manager.makeSessionState(label: "beta", name: nil)
    _ = try await manager.makeSessionState(label: nil, name: "third")
    let listed = await manager.allSessions()
    #expect(listed.map(\.shortId) == ids)
    #expect(listed.map(\.name) == ["first", nil, "third"])
    #expect(listed.map(\.label) == ["alpha", "beta", nil])
}

// MARK: - Test helpers

/// Sendable atomic counter for deterministic test sequences. Same
/// shape as `ManagedAtomicInt` in `SessionManagerTests`.
private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func incrementAndGet() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
