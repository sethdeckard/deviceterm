// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import DaemonTestSupport
import Foundation
import Testing

// The daemon-side half of the live tab label: a memory-only cache keyed by
// session, normalized on receipt, dropped with the session, and filtered by
// the same protection rule as the tab itself.

@Test
func cachesAndClearsTheDisplayTitle() async throws {
    let manager = SessionManager()
    let session = try await manager.makeSessionState()

    try await manager.setDisplayTitle(sessionId: session.id, title: "vim foo.swift", fromConnection: 1)
    #expect(await manager.displayTitle(session.id) == "vim foo.swift")

    try await manager.setDisplayTitle(sessionId: session.id, title: nil, fromConnection: 1)
    #expect(await manager.displayTitle(session.id) == nil)
}

@Test
func normalizesTheTitleDaemonSide() async throws {
    // The client normalizes too, but the daemon's pass is the enforcement:
    // it must hold regardless of what a client sends.
    let manager = SessionManager()
    let session = try await manager.makeSessionState()

    try await manager.setDisplayTitle(sessionId: session.id, title: "safe\u{202E}gnitiaps", fromConnection: 1)
    #expect(await manager.displayTitle(session.id) == "safegnitiaps")

    try await manager.setDisplayTitle(
        sessionId: session.id,
        title: String(repeating: "x", count: 4_000),
        fromConnection: 1
    )
    let bounded = try #require(await manager.displayTitle(session.id))
    #expect(bounded.utf8.count == DisplayTitleNormalizer.byteBudget)
}

@Test
func aTitleThatNormalizesToNothingClearsTheCachedOne() async throws {
    // Non-empty in, nothing survives: the previous label must NOT outlive
    // the value that replaced it.
    let manager = SessionManager()
    let session = try await manager.makeSessionState()

    try await manager.setDisplayTitle(sessionId: session.id, title: "real title", fromConnection: 1)
    try await manager.setDisplayTitle(sessionId: session.id, title: "\u{202A}\u{202C}", fromConnection: 1)
    #expect(await manager.displayTitle(session.id) == nil)
}

@Test
func aWriteFromAnOlderConnectionCannotOverwriteANewerTitle() async throws {
    // Handler tasks are not FIFO, so an older push can resume after its
    // replacement. If it landed, `tabs.list` would show the superseded
    // label with nothing to correct it until the title next changed.
    let manager = SessionManager()
    let session = try await manager.makeSessionState()

    try await manager.setDisplayTitle(sessionId: session.id, title: "new", fromConnection: 20)
    try await manager.setDisplayTitle(sessionId: session.id, title: "stale", fromConnection: 10)
    #expect(await manager.displayTitle(session.id) == "new")

    // A stale CLEAR is dropped for the same reason.
    try await manager.setDisplayTitle(sessionId: session.id, title: nil, fromConnection: 10)
    #expect(await manager.displayTitle(session.id) == "new")

    // The current connection keeps writing, and so does its successor.
    try await manager.setDisplayTitle(sessionId: session.id, title: "newer", fromConnection: 20)
    #expect(await manager.displayTitle(session.id) == "newer")
    try await manager.setDisplayTitle(sessionId: session.id, title: "newest", fromConnection: 21)
    #expect(await manager.displayTitle(session.id) == "newest")
}

@Test
func theWriterOrderingIsPerSessionNotDaemonWide() async throws {
    // Two GUI instances each publish their own sessions. A daemon-wide
    // high-water mark would let the newer connection starve the older one's
    // unrelated tabs.
    let manager = SessionManager()
    let mine = try await manager.makeSessionState()
    let theirs = try await manager.makeSessionState()

    try await manager.setDisplayTitle(sessionId: theirs.id, title: "theirs", fromConnection: 20)
    try await manager.setDisplayTitle(sessionId: mine.id, title: "mine", fromConnection: 10)
    #expect(await manager.displayTitle(mine.id) == "mine")
}

@Test
func rejectsADisplayTitleForAnUnknownSession() async throws {
    // A stale queued push must not accrete titles for dead sessions in a
    // map nothing would clean up.
    let manager = SessionManager()
    await #expect(throws: SessionError.self) {
        try await manager.setDisplayTitle(sessionId: UUID(), title: "ghost", fromConnection: 1)
    }
}

@Test
func closingASessionDropsItsDisplayTitle() async throws {
    // Session ids are unique, but a recycled SHORT id could otherwise
    // surface a dead tab's label.
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil, name: nil)
    try await manager.setDisplayTitle(sessionId: created.state.id, title: "vim", fromConnection: 1)
    try await manager.closeSession(
        sessionId: created.state.id,
        capability: created.capability
    )
    #expect(await manager.displayTitle(created.state.id) == nil)
}

@Test
func displayTitlesRideTheSameVisibilityFilterAsTheirTabs() async throws {
    // A protected tab's label is exactly as visible as the tab itself: the
    // pairing is computed from the already-filtered projection.
    let manager = SessionManager()
    let mine = try await manager.makeSessionState(name: "mine")
    let theirs = try await manager.makeSessionState(name: "theirs")
    try await manager.setDisplayTitle(sessionId: mine.id, title: "my title", fromConnection: 1)
    try await manager.setDisplayTitle(sessionId: theirs.id, title: "their secret", fromConnection: 1)
    try await manager.setProtectedBatch(
        sessionIds: [theirs.id],
        isProtected: true,
        revision: 1,
        epoch: 1
    )

    let visible = await manager.sessionsWithDisplayTitles(visibleTo: mine.id)
    #expect(visible.map(\.state.id) == [mine.id])
    #expect(visible.map(\.displayTitle) == ["my title"])

    let owner = await manager.sessionsWithDisplayTitles(visibleTo: theirs.id)
    #expect(owner.first { $0.state.id == theirs.id }?.displayTitle == "their secret")
}
