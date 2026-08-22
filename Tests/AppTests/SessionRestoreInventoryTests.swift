// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

// SessionRestoreInventory: the pure mapping from the live GUI model to the
// daemon's `session.restoreBatch` inventory. Pins: one entry per terminal
// session, tab-wide role, privacy derived FAIL-CLOSED from effective-hidden
// (not committed `isPrivate`), correct exclusion of un-provisioned terminals,
// a nil (fail-don't-partial) result when a live terminal is malformed, and
// order preservation (which defines the restored set's `tabs.list` order).

private func terminal(
    _ n: Int,
    sessionId: String,
    shortId: String?,
    name: String? = nil
) -> TerminalPaneState {
    TerminalPaneState(
        id: TerminalPaneID(value: n),
        sessionId: sessionId,
        capability: "cap-\(sessionId)",
        shortId: shortId,
        name: name
    )
}

private func tab(
    _ id: Int,
    terminals: [TerminalPaneState],
    role: SessionRole = .agent,
    privacy: TabPrivacyState = .publicVisible
) -> TabState {
    var state = TabState(id: TabID(value: id), terminals: terminals, simPanes: [], role: role)
    state.privacyState = privacy
    return state
}

@Test
func emitsOneEntryPerTerminalCarryingTabRoleAndTerminalFields() throws {
    let onlyTab = tab(
        1,
        terminals: [
            terminal(1, sessionId: "S1", shortId: "aaa111", name: "one"),
            terminal(2, sessionId: "S2", shortId: "bbb222", name: nil)
        ],
        role: .automation
    )
    let inventory = try #require(SessionRestoreInventory.build(from: [onlyTab]))
    #expect(inventory.count == 2)
    #expect(inventory[0].sessionId == "S1")
    #expect(inventory[0].capability == "cap-S1")
    #expect(inventory[0].shortId == "aaa111")
    #expect(inventory[0].name == "one")
    #expect(inventory[0].role == .automation)   // role is tab-wide
    #expect(inventory[0].isPrivate == false)
    #expect(inventory[1].sessionId == "S2")
    #expect(inventory[1].name == nil)
}

@Test
func privacyIsFailClosedFromEffectiveHiddenNotCommitted() throws {
    let hidden = tab(1, terminals: [terminal(1, sessionId: "S", shortId: "aaa111")], privacy: .privateHidden)
    let pending = tab(2, terminals: [terminal(2, sessionId: "T", shortId: "bbb222")], privacy: .pendingPrivate)
    let publicTab = tab(3, terminals: [terminal(3, sessionId: "U", shortId: "ccc333")], privacy: .publicVisible)

    let inventory = try #require(SessionRestoreInventory.build(from: [hidden, pending, publicTab]))
    // A mid-transition (`.pendingPrivate`) tab restores PRIVATE: never briefly
    // exposed as public.
    #expect(inventory[0].isPrivate == true)   // privateHidden
    #expect(inventory[1].isPrivate == true)   // pendingPrivate
    #expect(inventory[2].isPrivate == false)  // publicVisible
}

@Test
func excludesTerminalsWithNoSessionYet() throws {
    let onlyTab = tab(
        1,
        terminals: [
            terminal(1, sessionId: "", shortId: "aaa111"),        // no session yet
            terminal(2, sessionId: "S3", shortId: "ccc333")       // restorable
        ]
    )
    // An un-provisioned terminal (no daemon session) is correctly excluded:
    // there is nothing to restore, so the batch is still complete.
    let inventory = try #require(SessionRestoreInventory.build(from: [onlyTab]))
    #expect(inventory.map(\.sessionId) == ["S3"])
}

@Test
func returnsNilWhenALiveTerminalIsMissingItsShortId() {
    // A live session (non-empty sessionId) with no short id is a daemon-contract
    // violation. Rather than silently omit it and release the barrier with a
    // partial inventory, `build` returns nil so the caller retries.
    let onlyTab = tab(
        1,
        terminals: [
            terminal(1, sessionId: "S1", shortId: "aaa111"),
            terminal(2, sessionId: "S2", shortId: nil)            // live but malformed
        ]
    )
    #expect(SessionRestoreInventory.build(from: [onlyTab]) == nil)
}

@Test
func preservesTabThenTerminalOrder() throws {
    let inventory = try #require(SessionRestoreInventory.build(from: [
        tab(1, terminals: [
            terminal(1, sessionId: "A", shortId: "aaa111"),
            terminal(2, sessionId: "B", shortId: "bbb222")
        ]),
        tab(2, terminals: [terminal(3, sessionId: "C", shortId: "ccc333")])
    ]))
    #expect(inventory.map(\.sessionId) == ["A", "B", "C"])
}
