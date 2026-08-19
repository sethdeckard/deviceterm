// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
@testable import Daemon
import Foundation
import Testing

// MARK: - Pure (no CoreSimulator)
//
// The ownership map is the only daemon-internal state the
// coordinator owns; everything else lives in CoreSimulator. These
// tests exercise that map without touching the bridge, so they run
// on every host regardless of whether Xcode is installed.

@Test
func ownershipRecordAndLookupRoundTrip() async throws {
    let coordinator = DeviceCoordinator()
    let sessionId = UUID()
    let udid = UUID().uuidString
    try await coordinator.recordOwnership(udid: udid, sessionId: sessionId)
    let owner = await coordinator.ownerSession(forUDID: udid)
    #expect(owner == sessionId)
    let count = await coordinator.ownedCount
    #expect(count == 1)
}

@Test
func ownershipLookupIsCaseInsensitive() async throws {
    let coordinator = DeviceCoordinator()
    let sessionId = UUID()
    let udid = UUID().uuidString
    try await coordinator.recordOwnership(udid: udid.lowercased(), sessionId: sessionId)
    let upper = await coordinator.ownerSession(forUDID: udid.uppercased())
    #expect(upper == sessionId)
}

@Test
func releaseOwnershipRemovesEntry() async throws {
    let coordinator = DeviceCoordinator()
    let sessionId = UUID()
    let udid = UUID().uuidString
    try await coordinator.recordOwnership(udid: udid, sessionId: sessionId)
    await coordinator.releaseOwnership(udid: udid)
    let owner = await coordinator.ownerSession(forUDID: udid)
    #expect(owner == nil)
    let count = await coordinator.ownedCount
    #expect(count == 0)
}

@Test
func releaseOwnershipForSessionBatchDropsAllMatches() async throws {
    let coordinator = DeviceCoordinator()
    let sessionA = UUID()
    let sessionB = UUID()
    let udid1 = UUID().uuidString
    let udid2 = UUID().uuidString
    let udid3 = UUID().uuidString
    try await coordinator.recordOwnership(udid: udid1, sessionId: sessionA)
    try await coordinator.recordOwnership(udid: udid2, sessionId: sessionA)
    try await coordinator.recordOwnership(udid: udid3, sessionId: sessionB)
    await coordinator.releaseOwnership(for: [sessionA])
    let countAfter = await coordinator.ownedCount
    #expect(countAfter == 1)
    let owner = await coordinator.ownerSession(forUDID: udid3)
    #expect(owner == sessionB)
}

@Test
func recordOwnershipRejectsEmptyUDID() async throws {
    let coordinator = DeviceCoordinator()
    await #expect(throws: DeviceError.malformedUDID(udid: "")) {
        try await coordinator.recordOwnership(udid: "", sessionId: UUID())
    }
    await #expect(throws: DeviceError.malformedUDID(udid: "   ")) {
        try await coordinator.recordOwnership(udid: "   ", sessionId: UUID())
    }
}

@Test
func recordOwnershipRejectsNonUUIDString() async throws {
    // Any non-empty junk string must be rejected. Without the
    // format check a short "abc" still increments ownedCount, even
    // though CoreSimulator UDIDs are always UUID-formatted.
    let coordinator = DeviceCoordinator()
    await #expect(throws: DeviceError.malformedUDID(udid: "abc")) {
        try await coordinator.recordOwnership(udid: "abc", sessionId: UUID())
    }
    await #expect(throws: DeviceError.malformedUDID(udid: "not-a-uuid")) {
        try await coordinator.recordOwnership(udid: "not-a-uuid", sessionId: UUID())
    }
    let count = await coordinator.ownedCount
    #expect(count == 0, "malformed UDID must not increment ownedCount")
}

@Test
func ownerSessionForUnknownUDIDReturnsNil() async {
    let coordinator = DeviceCoordinator()
    let owner = await coordinator.ownerSession(forUDID: UUID().uuidString)
    #expect(owner == nil)
}

@Test
func ownedBootedCountIgnoresStaleOwnershipForUnknownUDIDs() async throws {
    // Owned UDIDs that aren't in CoreSimulator's device set get
    // filtered out by `listOwned`'s intersection, so stale ghost
    // entries can't inflate the count even when ownedCount > 0.
    let coordinator = DeviceCoordinator()
    let sessionId = UUID()
    let ghostUDID = UUID().uuidString
    try await coordinator.recordOwnership(udid: ghostUDID, sessionId: sessionId)
    let rawCount = await coordinator.ownedCount
    #expect(rawCount == 1)
    // No real device matches that UDID, so the intersection is
    // empty and ownedBootedCount returns 0.
    let bootedCount = await coordinator.ownedBootedCount()
    #expect(bootedCount == 0)
}

@Test
func ownedBootedCountReturnsZeroWhenNothingOwned() async {
    let coordinator = DeviceCoordinator(readDevices: {
        Issue.record("empty ownership must not enumerate CoreSimulator")
        return []
    })
    let count = await coordinator.ownedBootedCount()
    #expect(count == 0)
}

@Test
func listOwnedBootedReturnsEmptyWhenNothingOwned() async {
    let coordinator = DeviceCoordinator(readDevices: {
        Issue.record("empty ownership must not enumerate CoreSimulator")
        return []
    })
    let sims = await coordinator.listOwnedBooted()
    #expect(sims.isEmpty)
}

// MARK: - Live (CoreSimulator-gated)

private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func liveListAllReturnsDevices() async throws {
    let coordinator = DeviceCoordinator()
    let devices = try await coordinator.listAll()
    #expect(!devices.isEmpty, "developer host should have at least one device")
}

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func liveListOwnedStartsEmpty() async throws {
    let coordinator = DeviceCoordinator()
    let owned = try await coordinator.listOwned()
    #expect(owned.isEmpty)
}

@Test(.disabled(if: !coreSimulatorAvailable, "CoreSimulator not available on host"))
func liveListOwnedReturnsRecordedSimsOnly() async throws {
    let coordinator = DeviceCoordinator()
    // Pick a real UDID from the host's device set, mark it owned,
    // and confirm listOwned narrows to just that one.
    let all = try await coordinator.listAll()
    guard let pick = all.first else {
        Issue.record("host has no devices to fixture against")
        return
    }
    try await coordinator.recordOwnership(udid: pick.udid, sessionId: UUID())
    let owned = try await coordinator.listOwned()
    #expect(owned.count == 1)
    #expect(owned.first?.udid.lowercased() == pick.udid.lowercased())
}
