// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif

// TerminalAnchorStore: the in-memory session→terminal binding registry.
// Driven with synthetic facts so binding, immutability, issuer transfer, and
// live-session linearization are exercised without real terminals.

private func facts(_ sid: pid_t, _ start: UInt64, _ dev: dev_t) -> TerminalAnchorFacts {
    TerminalAnchorFacts(
        terminalSessionId: sid,
        sessionLeaderStartTime: start,
        controllingTTYDevice: dev
    )
}

/// Register `id` as a live session and return it.
private func live(_ store: TerminalAnchorStore, _ id: UUID) async -> UUID {
    await store.registerSession(id)
    return id
}

@Test
func bindThenAnchorReturnsIt() async {
    let store = TerminalAnchorStore()
    let session = await live(store, UUID())
    #expect(await store.anchor(for: session) == nil)
    #expect(await store.bind(sessionId: session, facts: facts(100, 1, 5), issuedBy: 1) == .applied)
    let anchor = await store.anchor(for: session)
    #expect(anchor?.facts == facts(100, 1, 5))
    #expect(anchor?.issuingGUIConnectionId == 1)
}

@Test
func bindForUnregisteredSessionIsRejected() async {
    let store = TerminalAnchorStore()
    #expect(await store.bind(sessionId: UUID(), facts: facts(100, 1, 5), issuedBy: 1) == .sessionNotLive)
}

@Test
func identicalRebindIsIdempotent() async {
    let store = TerminalAnchorStore()
    let session = await live(store, UUID())
    _ = await store.bind(sessionId: session, facts: facts(100, 1, 5), issuedBy: 1)
    #expect(await store.bind(sessionId: session, facts: facts(100, 1, 5), issuedBy: 1) == .applied)
    #expect(await store.count == 1)
}

@Test
func identicalRebindFromNewerConnectionSurvivesOldTeardown() async {
    // The reconnect case: a newer GUI connection re-binds the identical
    // anchor, taking ownership, so the OLD connection's delayed teardown can't
    // remove the anchor the new connection just confirmed.
    let store = TerminalAnchorStore()
    let session = await live(store, UUID())
    _ = await store.bind(sessionId: session, facts: facts(100, 1, 5), issuedBy: 1)
    #expect(await store.bind(sessionId: session, facts: facts(100, 1, 5), issuedBy: 2) == .applied)
    #expect(await store.anchor(for: session)?.issuingGUIConnectionId == 2)
    await store.revokeAll(issuedBy: 1)  // old connection tears down
    #expect(await store.anchor(for: session)?.facts == facts(100, 1, 5))  // survives
}

@Test
func olderConnectionRebindDoesNotReclaimOwnershipFromNewer() async {
    // Reverse order: connection 2 already owns the anchor; a suspended request
    // from the OLDER connection 1 resumes and re-binds the identical anchor.
    // It succeeds idempotently but must NOT reclaim ownership, so connection
    // 1's later close can't remove the anchor connection 2 confirmed.
    let store = TerminalAnchorStore()
    let session = await live(store, UUID())
    _ = await store.bind(sessionId: session, facts: facts(100, 1, 5), issuedBy: 1)
    _ = await store.bind(sessionId: session, facts: facts(100, 1, 5), issuedBy: 2)
    #expect(await store.anchor(for: session)?.issuingGUIConnectionId == 2)
    #expect(await store.bind(sessionId: session, facts: facts(100, 1, 5), issuedBy: 1) == .applied)
    #expect(await store.anchor(for: session)?.issuingGUIConnectionId == 2)  // not reclaimed
    await store.revokeAll(issuedBy: 1)  // older connection closes
    #expect(await store.anchor(for: session)?.facts == facts(100, 1, 5))  // survives
}

@Test
func differentRebindOnLiveSessionConflicts() async {
    let store = TerminalAnchorStore()
    let session = await live(store, UUID())
    _ = await store.bind(sessionId: session, facts: facts(100, 1, 5), issuedBy: 1)
    #expect(await store.bind(sessionId: session, facts: facts(200, 9, 7), issuedBy: 1) == .conflict)
    #expect(await store.anchor(for: session)?.facts == facts(100, 1, 5))
}

@Test
func bindFromRetiredIssuerRejected() async {
    let store = TerminalAnchorStore()
    let session = await live(store, UUID())
    await store.revokeAll(issuedBy: 5)
    #expect(await store.bind(sessionId: session, facts: facts(100, 1, 5), issuedBy: 5) == .issuerRetired)
    #expect(await store.anchor(for: session) == nil)
    #expect(await store.bind(sessionId: session, facts: facts(100, 1, 5), issuedBy: 6) == .applied)
}

@Test
func removedSessionRejectsAnyLateBind() async {
    // A handler that confirmed liveness, suspended, and resumes after the
    // session was removed must NOT recreate an anchor for the dead session.
    let store = TerminalAnchorStore()
    let session = await live(store, UUID())
    _ = await store.bind(sessionId: session, facts: facts(100, 1, 5), issuedBy: 1)
    await store.revokeForRemovedSession(session)
    #expect(await store.anchor(for: session) == nil)
    #expect(await store.bind(sessionId: session, facts: facts(100, 1, 5), issuedBy: 1) == .sessionNotLive)
}

@Test
func revokeAllClearsOnlyThatConnectionsAnchors() async {
    let store = TerminalAnchorStore()
    let ownedByOne = await live(store, UUID())
    let ownedByTwo = await live(store, UUID())
    _ = await store.bind(sessionId: ownedByOne, facts: facts(100, 1, 5), issuedBy: 1)
    _ = await store.bind(sessionId: ownedByTwo, facts: facts(200, 2, 6), issuedBy: 2)
    await store.revokeAll(issuedBy: 1)
    #expect(await store.anchor(for: ownedByOne) == nil)
    #expect(await store.anchor(for: ownedByTwo)?.facts == facts(200, 2, 6))
}
