// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import Testing

// The close flows ask different questions of the same owned roster. Tab and
// window close filter Booted sims by the sessions they are about to close.
// Pane close starts from one udid and rejects only sims a live session in
// another tab claims, so a dead owner or no owner at all still counts.
//
// Get either wrong in one direction and the user is asked about a sim that
// isn't theirs to stop; wrong in the other and a running sim is abandoned
// without a word. `OwnedSimDecision` is pure so those rules can be pinned
// directly, with the `device.list` read tested separately below.

private func entry(
    udid: String,
    state: String,
    session: String?
) -> DeviceListEntry {
    DeviceListEntry(udid: udid, name: "iPhone 17 Pro", state: state, ownedBySession: session)
}

private let roster = [
    entry(udid: "AAAA-1", state: "Booted", session: "s1"),
    entry(udid: "BBBB-2", state: "Shutdown", session: "s1"),
    entry(udid: "CCCC-3", state: "Booted", session: "s2"),
    // Owned by deviceterm, attributed to nobody: the Unlinked shape.
    entry(udid: "DDDD-4", state: "Booted", session: nil)
]

@Test("bootedEntry finds only a running sim in the owned roster", arguments: [
    // Owned and running: the case with something to decide.
    ("AAAA-1", true),
    // Already shut down behind the pane's overlay.
    ("BBBB-2", false),
    ("CCCC-3", true),
    // Unlinked: owned and running with no session behind it.
    ("DDDD-4", true),
    // Not in the owned roster: a borrowed sim, not deviceterm's to stop.
    ("EEEE-5", false)
])
func resolvesOwnedBootedSim(udid: String, expected: Bool) {
    #expect((OwnedSimDecision.bootedEntry(udid: udid, in: roster) != nil) == expected)
}

@Test
func bootedEntryKeepsTheAttributionForTheCallerToJudge() {
    // The verdict can't be folded in here: tab membership has to be sampled
    // after the roster read returns, so the entry carries the attribution
    // out rather than resolving it.
    let found = OwnedSimDecision.bootedEntry(udid: "CCCC-3", in: roster)
    #expect(found?.ownedBySession == "s2")
    #expect(OwnedSimDecision.bootedEntry(udid: "DDDD-4", in: roster)?.ownedBySession == nil)
}

@Test
func aSimOutlivingItsBooterIsStillOursToStop() {
    // Closing the terminal that booted a sim drops that session from the tab
    // and closes it daemon-side, but disowns nothing. The sim stays owned and
    // Booted under a session that no longer exists, and its pane is still
    // mounted. Gating on a live session would detach it without a word.
    #expect(
        OwnedSimDecision.isOursToStop(
            ownedBySession: "dead-session",
            claimedElsewhere: ["some-other-live-session"]
        )
    )
    // Unlinked, attributed to nobody at all: same answer.
    #expect(
        OwnedSimDecision.isOursToStop(ownedBySession: nil, claimedElsewhere: ["tab-b"])
    )
    // Tab and window close keep their session filter: they close the
    // sessions themselves, and their shutdown fan-out is session-scoped.
    let orphaned = [entry(udid: "AAAA-1", state: "Booted", session: "dead-session")]
    #expect(!OwnedSimDecision.anyBooted(ownedBy: ["s1"], in: orphaned))
}

@Test
func aSimAnotherLiveTabIsUsingIsNotOursToStop() {
    // Boot a udid from tab B after tab A's copy stopped: B gets a live pane,
    // A keeps a stale shut-down one for the same udid. Closing A's stale
    // pane must not offer to stop the simulator B is using.
    #expect(
        !OwnedSimDecision.isOursToStop(ownedBySession: "tab-b", claimedElsewhere: ["tab-b"])
    )
    // Judged from tab B itself, whose own session is not "elsewhere".
    #expect(OwnedSimDecision.isOursToStop(ownedBySession: "tab-b", claimedElsewhere: []))
}

@Test("udid case does not decide ownership", arguments: ["aaaa-1", "AAAA-1", "AaAa-1"])
func matchesUDIDCaseInsensitively(udid: String) {
    // Pane state, `device.list`, and the CLI don't agree on case, and a
    // miss here reads as "nothing to ask about" and silently detaches.
    #expect(OwnedSimDecision.bootedEntry(udid: udid, in: roster) != nil)
}

@Test
func anyBootedSeesOnlyAttributedLiveSims() {
    #expect(OwnedSimDecision.anyBooted(ownedBy: ["s1"], in: roster))
    // s3 owns nothing; the Unlinked and other-session entries don't count.
    #expect(!OwnedSimDecision.anyBooted(ownedBy: ["s3"], in: roster))
    #expect(!OwnedSimDecision.anyBooted(ownedBy: [], in: roster))
    #expect(!OwnedSimDecision.anyBooted(ownedBy: ["s1"], in: []))
}

@Test
func bootedKeepsRosterOrderAndDropsTheRest() {
    let booted = OwnedSimDecision.booted(ownedBy: ["s1", "s2"], in: roster)
    #expect(booted.map(\.udid) == ["AAAA-1", "CCCC-3"])
}

// MARK: - The read around it

private struct DaemonDown: Error {}

@MainActor
@Test
func aFailedRosterReadIsUnknownRatherThanYesOrNo() async {
    // Neither collapse is safe. `false` silently detaches a sim the user
    // would have been asked about; `true` lets a stored `shutdown` stop a
    // simulator nothing verified. The caller has to see the difference.
    let fake = FakeDaemonClient()
    fake.deviceListResult = roster
    fake.deviceListError = DaemonDown()
    #expect(await fake.lookUpOwnedSim(udid: "AAAA-1") == .unknown)
    // Including for a sim that isn't in the roster at all.
    #expect(await fake.lookUpOwnedSim(udid: "EEEE-5") == .unknown)
    // Tab close still gates on a Bool and treats a failed read as affected.
    // That only reaches its prompt when nothing is stored; a stored close
    // default is applied first.
    #expect(await fake.hasOwnedBootedSims(forSessions: ["s1"]))
}

@MainActor
@Test
func successfulRosterReadAnswersFromTheRoster() async {
    let fake = FakeDaemonClient()
    fake.deviceListResult = roster
    #expect(await fake.hasOwnedBootedSims(forSessions: ["s1"]))
    #expect(!(await fake.hasOwnedBootedSims(forSessions: ["s3"])))
    #expect(await fake.lookUpOwnedSim(udid: "AAAA-1") == .running(ownedBySession: "s1"))
    #expect(await fake.lookUpOwnedSim(udid: "DDDD-4") == .running(ownedBySession: nil))
    #expect(await fake.lookUpOwnedSim(udid: "BBBB-2") == .notRunning)
    #expect(await fake.lookUpOwnedSim(udid: "EEEE-5") == .notRunning)
    #expect(fake.deviceListCalls.allSatisfy { $0.scope == .owned })
}
