// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import IOSurface
import Testing

/// Counts lease releases, which `SurfaceLease` signals from `deinit`.
private final class ReleaseLog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.pair-table.releases")
    private var released: [UInt64] = []

    var generations: [UInt64] { queue.sync { released } }

    func record(_ key: SurfaceLease.ReleaseKey) {
        queue.sync { released.append(key.generation) }
    }
}

private struct PairFixture {
    let paneId = "pane-a"
    let token = UUID()
    let log = ReleaseLog()
    let start = Date(timeIntervalSinceReferenceDate: 0)

    func key(_ sequence: UInt64, token: UUID? = nil, paneId: String? = nil) -> SurfacePairTable.Key {
        SurfacePairTable.Key(paneId: paneId ?? self.paneId, sequence: sequence, token: token ?? self.token)
    }

    func event(_ sequence: UInt64) -> SurfaceChangedEvent {
        SurfaceChangedEvent(paneId: paneId, sequence: sequence)
    }

    func lease(_ sequence: UInt64) throws -> SurfaceLease {
        let surface = try #require(IOSurfaceCreate([
            kIOSurfaceWidth: 4, kIOSurfaceHeight: 4, kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: 0x4247_5241
        ] as CFDictionary))
        let log = self.log
        return SurfaceLease(
            surface: surface,
            paneId: paneId,
            subscriptionToken: token,
            leaseEpoch: 1,
            generation: sequence,
            onRelease: { log.record($0) }
        )
    }
}

@Test("a JSON-first pair yields when its side-band arrives")
func pairYieldsWhenBothHalvesArrive() throws {
    let fixture = PairFixture()
    var table = SurfacePairTable()
    #expect(table.offer(fixture.key(1), now: fixture.start, event: fixture.event(1)) == nil)
    let resolved = try #require(table.offer(fixture.key(1), now: fixture.start, lease: try fixture.lease(1)))
    #expect(resolved.event.sequence == 1)
    #expect(resolved.lease?.generation == 1)
    #expect(table.isEmpty)
}

@Test("a yield drops an older side-band-only half and releases its lease")
func yieldEvictsOlderSideBand() throws {
    let fixture = PairFixture()
    var table = SurfacePairTable()
    // Frame 1's JSON notice was folded away on the daemon.
    #expect(table.offer(fixture.key(1), now: fixture.start, lease: try fixture.lease(1)) == nil)
    #expect(fixture.log.generations.isEmpty)
    _ = table.offer(fixture.key(2), now: fixture.start, event: fixture.event(2))
    let resolved = table.offer(fixture.key(2), now: fixture.start, lease: try fixture.lease(2))
    #expect(resolved?.event.sequence == 2)
    #expect(table.isEmpty)
    #expect(fixture.log.generations == [1])
}

@Test("a yield drops an older JSON-only half, so the sweep never delivers it")
func yieldEvictsOlderJSON() throws {
    let fixture = PairFixture()
    var table = SurfacePairTable()
    // Frame 1's side-band was skipped by the daemon's delivery worker.
    _ = table.offer(fixture.key(1), now: fixture.start, event: fixture.event(1))
    _ = table.offer(fixture.key(2), now: fixture.start, event: fixture.event(2))
    _ = table.offer(fixture.key(2), now: fixture.start, lease: try fixture.lease(2))
    #expect(table.sweep(now: fixture.start.addingTimeInterval(1), maxAge: 0.25).isEmpty)
}

@Test("a half at or below the newest yield is dropped on arrival")
func lateHalfIsDroppedOnArrival() throws {
    let fixture = PairFixture()
    var table = SurfacePairTable()
    _ = table.offer(fixture.key(2), now: fixture.start, event: fixture.event(2))
    _ = table.offer(fixture.key(2), now: fixture.start, lease: try fixture.lease(2))
    // A subscribe replay of frame 1 reaching the GUI after live frame 2.
    #expect(table.offer(fixture.key(1), now: fixture.start, lease: try fixture.lease(1)) == nil)
    #expect(table.offer(fixture.key(1), now: fixture.start, event: fixture.event(1)) == nil)
    #expect(table.isEmpty)
    #expect(fixture.log.generations.contains(1))
}

@Test("a yield leaves other subscriptions and panes alone")
func yieldIsScopedToItsSubscription() throws {
    let fixture = PairFixture()
    var table = SurfacePairTable()
    let otherToken = UUID()
    _ = table.offer(fixture.key(1, token: otherToken), now: fixture.start, event: fixture.event(1))
    _ = table.offer(fixture.key(1, paneId: "pane-b"), now: fixture.start, event: fixture.event(1))
    _ = table.offer(fixture.key(2), now: fixture.start, event: fixture.event(2))
    _ = table.offer(fixture.key(2), now: fixture.start, lease: try fixture.lease(2))
    #expect(table.count == 2)
}

@Test("the sweep yields only the newest JSON-only half per subscription and drops side-band halves")
func sweepYieldsNewestJSONOnly() throws {
    let fixture = PairFixture()
    var table = SurfacePairTable()
    _ = table.offer(fixture.key(1), now: fixture.start, event: fixture.event(1))
    _ = table.offer(fixture.key(2), now: fixture.start, event: fixture.event(2))
    _ = table.offer(fixture.key(3), now: fixture.start, lease: try fixture.lease(3))
    // Too young to sweep.
    #expect(table.sweep(now: fixture.start.addingTimeInterval(0.1), maxAge: 0.25).isEmpty)

    let expired = table.sweep(now: fixture.start.addingTimeInterval(0.3), maxAge: 0.25)
    #expect(expired.map(\.event.sequence) == [2])
    #expect(expired.first?.lease == nil)
    #expect(table.isEmpty)
    #expect(fixture.log.generations == [3])
    // A late side-band for the swept frame is dropped rather than parked.
    #expect(table.offer(fixture.key(2), now: fixture.start, lease: try fixture.lease(2)) == nil)
    #expect(table.isEmpty)
}

@Test("forgetting a subscription drops its halves and its yield history")
func forgetDropsASubscription() throws {
    let fixture = PairFixture()
    var table = SurfacePairTable()
    _ = table.offer(fixture.key(2), now: fixture.start, event: fixture.event(2))
    _ = table.offer(fixture.key(2), now: fixture.start, lease: try fixture.lease(2))
    _ = table.offer(fixture.key(3), now: fixture.start, lease: try fixture.lease(3))
    table.forget(token: fixture.token)
    #expect(table.isEmpty)
    #expect(fixture.log.generations.contains(3))
    // With its history gone, a lower sequence parks again.
    _ = table.offer(fixture.key(1), now: fixture.start, event: fixture.event(1))
    #expect(table.count == 1)
}
