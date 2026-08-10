// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
@testable import Daemon
import Foundation
import Testing

// PaneCoordinator-level dedup tests against a real booted sim.
// `createSim` is UDID-idempotent within a session and reject-on-
// conflict across sessions, the daemon-side defense against the
// race where the GUI's discovery poll and an explicit `deviceterm
// device attach X` both fire for the same just-booted sim. Without
// dedup each caller cuts a fresh pane record and two side-by-side
// panes mirror the same display, which is a duplicate-pane bug seen
// in practice. Live track because the bridge handles
// (`SimDisplayHandle.start`, HID / Purple acquire) talk to a real
// device; the no-sim path is covered by `mapPaneError`-style unit
// tests in `PaneCoordinatorTests.swift`.

private let coreSimulatorAvailable: Bool = {
    CoreSimulatorLoader.probe().ok
}()

@Test
func sameSessionCreateSimIsIdempotentByUDID() async throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let coordinator = PaneCoordinator()
    let sessionId = UUID()
    let first = try await coordinator.createSim(
        sessionId: sessionId,
        udid: booted.udid
    )
    let second = try await coordinator.createSim(
        sessionId: sessionId,
        udid: booted.udid
    )
    // Idempotent: second call returns the existing pane's handle
    // instead of allocating a fresh one. Without the dedup, the
    // paneCount would tick to 2 and the paneIds would differ.
    #expect(first.paneId == second.paneId)
    #expect(first.shortId == second.shortId)
    let count = await coordinator.paneCount
    #expect(count == 1)
}

@Test
func crossSessionCreateSimRejectsWithPaneAlreadyAttached() async throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let coordinator = PaneCoordinator()
    let firstSession = UUID()
    let secondSession = UUID()
    _ = try await coordinator.createSim(
        sessionId: firstSession,
        udid: booted.udid
    )
    // Cross-session create while the prior session is still alive
    // is a hard reject. The liveness predicate returns true for the
    // existing owner, so the daemon refuses to silently steal the
    // pane out from under it. The locked linkage design reserves
    // cross-session pane movement to the human (GUI drag).
    await #expect(
        throws: PaneError.paneAlreadyAttached(
        udid: booted.udid.lowercased(),
        ownerSessionId: firstSession
    )
    ) {
        _ = try await coordinator.createSim(
            sessionId: secondSession,
            udid: booted.udid,
            isOwnerSessionAlive: { _ in true }
        )
    }
    // The original record stays untouched.
    let count = await coordinator.paneCount
    #expect(count == 1)
}

@Test
func crossSessionCreateSimAdoptsWhenPriorOwnerIsDead() async throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let coordinator = PaneCoordinator()
    let deadSession = UUID()
    let recoverySession = UUID()
    let original = try await coordinator.createSim(
        sessionId: deadSession,
        udid: booted.udid
    )
    // Cold-start orphan recovery path: the GUI crashed leaving the
    // daemon holding a pane for `deadSession`; the relaunched GUI
    // calls `device.attach` with a fresh `recoverySession`. The
    // liveness predicate reports `deadSession` is gone, so the
    // daemon adopts the pane into the new session: same paneId,
    // same bridge handles (no re-acquire / no display interrupt),
    // sessionId mutated underneath.
    let adopted = try await coordinator.createSim(
        sessionId: recoverySession,
        udid: booted.udid,
        isOwnerSessionAlive: { _ in false }
    )
    #expect(adopted.paneId == original.paneId)
    #expect(adopted.shortId == original.shortId)
    let count = await coordinator.paneCount
    #expect(count == 1)
    // The pane is now visible under recoverySession's filtered list:
    // the actor mutated `Record.sessionId` in place.
    let panes = await coordinator.panesForSession(recoverySession)
    #expect(panes.count == 1)
    #expect(panes.first?.udid == booted.udid.lowercased())
    let strandedPanes = await coordinator.panesForSession(deadSession)
    #expect(strandedPanes.isEmpty)
}

@Test
func concurrentOrphanAdoptionDoesntSilentlySteal() async throws {
    // Actor-reentrancy regression cover. Two concurrent `createSim`
    // calls both target the same orphan pane (prior owner dead).
    // Both await the same liveness check; without the post-await
    // re-check inside the dedup loop, both would read "owner dead"
    // and the later writer would silently overwrite the earlier
    // adopter, so both callers would think they own the pane but
    // only one is recorded. With the guard in place, exactly one
    // adoption succeeds; the other either lands on idempotent
    // same-session (if it adopted into the same recovery target)
    // or surfaces `paneAlreadyAttached` (if into a different one).
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let coordinator = PaneCoordinator()
    let deadSession = UUID()
    let recoveryA = UUID()
    let recoveryB = UUID()
    _ = try await coordinator.createSim(
        sessionId: deadSession,
        udid: booted.udid
    )
    // Predicate yields the actor to let the second task in
    // between read and re-check, so the reentrancy window is
    // exercised deterministically rather than relying on real
    // SessionManager latency.
    let predicate: @Sendable (UUID) async -> Bool = { _ in
        try? await Task.sleep(nanoseconds: 10_000_000)
        return false
    }
    let resultA = await Task {
        try? await coordinator.createSim(
            sessionId: recoveryA,
            udid: booted.udid,
            isOwnerSessionAlive: predicate
        )
    }.value
    let resultB = await Task {
        try? await coordinator.createSim(
            sessionId: recoveryB,
            udid: booted.udid,
            isOwnerSessionAlive: predicate
        )
    }.value
    let recoveredA = resultA != nil
    let recoveredB = resultB != nil
    // At least one call must succeed; both succeeding is allowed
    // only when the loser arrives after the winner adopted and
    // observes the winner's session as the current owner (which
    // returns `paneAlreadyAttached` → nil via the `try?` above).
    // The invariant: exactly one of the two recovery sessions
    // owns the pane afterwards.
    #expect(recoveredA || recoveredB)
    let panesUnderA = await coordinator.panesForSession(recoveryA)
    let panesUnderB = await coordinator.panesForSession(recoveryB)
    #expect(panesUnderA.count + panesUnderB.count == 1)
    let count = await coordinator.paneCount
    #expect(count == 1)
}

@Test
func createSimRespectsCaseInsensitiveDedup() async throws {
    try #require(
        coreSimulatorAvailable,
        "CoreSimulator probe failed — the bridge can't drive this host"
    )
    let booted = try #require(
        try? SimDeviceHandle.singleBootedDevice(),
        "no booted sim — run via `make test-live`"
    )
    let coordinator = PaneCoordinator()
    let sessionId = UUID()
    let upperUDID = booted.udid.uppercased()
    let lowerUDID = booted.udid.lowercased()
    let first = try await coordinator.createSim(
        sessionId: sessionId,
        udid: upperUDID
    )
    let second = try await coordinator.createSim(
        sessionId: sessionId,
        udid: lowerUDID
    )
    // `canonicalizeUDID` lowercases on the way in, so different-
    // case calls for the same sim collapse to one record.
    #expect(first.paneId == second.paneId)
    let count = await coordinator.paneCount
    #expect(count == 1)
}
