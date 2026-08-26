// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

private let simA = "aaaaaaaa-1111-1111-1111-111111111111"
private let simB = "bbbbbbbb-2222-2222-2222-222222222222"
private let sessionA = "11111111-aaaa-aaaa-aaaa-111111111111"
private let sessionB = "22222222-bbbb-bbbb-bbbb-222222222222"

private func owned(
    _ udid: String,
    session: String?,
    state: String = "Booted"
) -> DeviceListEntry {
    DeviceListEntry(udid: udid, name: "sim", state: state, ownedBySession: session)
}

/// The GUI's mirror of which sims deviceterm owns.
///
/// Ownership lives in the helper's memory alone, so for a sim the user
/// detached this is the only live, trusted claim automatic warm-restart
/// recovery can act on. The mirror's whole job
/// is to still be holding that record at the moment a replacement helper says
/// it owns nothing, which is why every read carries the connection that
/// answered it: "the helper owns nothing" is a fact about one helper, and
/// adopting it from a replacement would erase what recovery exists to restore.
///
/// Reads take their token through `beginRead()` here, as the poll does, so the
/// ordering the mirror sees is the ordering production hands it.
@MainActor
struct OwnedSimRosterTests {
    /// One poll: claim a token, then hand the answer back under it.
    private func poll(
        _ roster: OwnedSimRoster,
        _ entries: [DeviceListEntry],
        generation: Int
    ) {
        guard let token = roster.beginRead() else {
            Issue.record("the roster read slot should be free between polls")
            return
        }
        roster.record(entries, generation: generation, read: token)
        roster.endRead(token)
    }

    @Test
    func aFreshRosterHasNothingToRestore() {
        // A GUI that just launched owns nothing it can prove. Sims left
        // running by a previous launch are the cold-start orphan prompt's
        // business, and claiming them here would bypass the human
        // confirmation that path exists for.
        let roster = OwnedSimRoster()

        #expect(roster.beginRestore() == nil)
        #expect(!roster.isAwaitingRestore)
    }

    @Test
    func theFirstReadSetsWhatTheMirrorBelieves() {
        // The transport numbers connections from one, and a cold start
        // replaces nothing, so there is nothing yet to disbelieve. A mirror
        // that started out trusting generation zero would drop every read and
        // never hold a claim at all.
        let roster = OwnedSimRoster()
        poll(roster, [owned(simA, session: sessionA)], generation: 1)

        roster.connectionReplaced(generation: 2)

        #expect(roster.beginRestore()?.claims.map(\.udid) == [simA])
    }

    @Test
    func aReplacementHelperIsToldWhatTheOldOneOwned() {
        let roster = OwnedSimRoster()
        poll(roster, [owned(simA, session: sessionA)], generation: 1)

        roster.connectionReplaced(generation: 2)

        #expect(
            roster.beginRestore() == OwnedSimRestore(
                generation: 2,
                claims: [RestoredSimOwnership(udid: simA, sessionId: sessionA)]
            )
        )
    }

    @Test
    func aReplacementHelpersOwnAnswerDoesNotEraseTheClaims() {
        // The case the generation tag exists for. A fresh helper answering
        // "nothing is owned" is answering correctly, and it arrives on the
        // 2-second poll cadence, so it can easily land before recovery runs.
        let roster = OwnedSimRoster()
        poll(roster, [owned(simA, session: sessionA)], generation: 1)
        roster.connectionReplaced(generation: 2)

        poll(roster, [], generation: 2)

        #expect(roster.beginRestore()?.claims.map(\.udid) == [simA])
    }

    @Test
    func theNewHelperIsBelievedOnceRestoreHasSettled() {
        let roster = OwnedSimRoster()
        poll(roster, [owned(simA, session: sessionA)], generation: 1)
        roster.connectionReplaced(generation: 2)
        roster.settle(generation: 2)

        poll(roster, [owned(simB, session: sessionB)], generation: 2)
        roster.connectionReplaced(generation: 3)

        #expect(roster.beginRestore()?.claims.map(\.udid) == [simB])
    }

    @Test
    func settlingASupersededAttemptLeavesTheNewerOnesWindowOpen() {
        // A second restart while the first re-assertion is still in flight.
        // If the older attempt could settle whatever happens to be pending,
        // the newer helper would be told nothing at all.
        let roster = OwnedSimRoster()
        poll(roster, [owned(simA, session: sessionA)], generation: 1)
        roster.connectionReplaced(generation: 2)
        roster.connectionReplaced(generation: 3)

        roster.settle(generation: 2)

        #expect(roster.isAwaitingRestore)
        #expect(roster.beginRestore()?.generation == 3)
        roster.settle(generation: 3)
        #expect(!roster.isAwaitingRestore)
    }

    @Test
    func aSettledRosterTracksTheHelperItIsTalkingTo() {
        // Wholesale replacement, not a merge: at a settled generation the
        // helper is the authority, so a sim it no longer reports as owned
        // (the user shut it down) must leave the mirror rather than being
        // re-asserted at the next restart.
        let roster = OwnedSimRoster()
        poll(
            roster,
            [owned(simA, session: sessionA), owned(simB, session: sessionB)],
            generation: 1
        )

        poll(roster, [owned(simB, session: sessionB)], generation: 1)
        roster.connectionReplaced(generation: 2)

        #expect(roster.beginRestore()?.claims.map(\.udid) == [simB])
    }

    @Test
    func everySimInTheOwnedRosterIsAClaimWhateverItsState() {
        // `.owned` has already answered "is this deviceterm's", so a missing
        // session says nobody is attributed rather than that nobody owns it,
        // and that Unlinked form is exactly how the helper reports one back
        // after restoration.
        //
        // State isn't filtered either. `.owned` is already the helper's
        // ownership decision; whether the simulator is still up is checked
        // again when a replacement helper evaluates restoration.
        let roster = OwnedSimRoster()

        poll(
            roster,
            [
                owned(simA, session: nil),
                owned(simB, session: sessionB, state: "Booting")
            ],
            generation: 1
        )
        roster.connectionReplaced(generation: 2)

        #expect(
            roster.beginRestore()?.claims == [
                RestoredSimOwnership(udid: simA, sessionId: nil),
                RestoredSimOwnership(udid: simB, sessionId: sessionB)
            ]
        )
    }

    @Test
    func aRestoreIsStillOwedWhenThereIsNothingToRestore() {
        // Non-nil with no claims is not the same as nil: the caller still
        // owes a settle, or the mirror never starts believing the new helper.
        let roster = OwnedSimRoster()
        roster.connectionReplaced(generation: 1)

        #expect(roster.beginRestore()?.claims.isEmpty == true)
        roster.settle(generation: 1)
        poll(roster, [owned(simA, session: sessionA)], generation: 1)
        roster.connectionReplaced(generation: 2)
        #expect(roster.beginRestore()?.claims.map(\.udid) == [simA])
    }

    @Test
    func udidsAreNormalizedToMatchTheDaemonsOwnKeys() {
        let roster = OwnedSimRoster()
        poll(roster, [owned(simA.uppercased(), session: sessionA)], generation: 1)
        roster.connectionReplaced(generation: 2)

        #expect(roster.beginRestore()?.claims.map(\.udid) == [simA])
    }

    // MARK: - Ordering

    @Test
    func onlyOneRosterReadRunsAtATime() {
        // Neither the order requests go out in nor the order answers come back
        // in says which snapshot the daemon took later, and it vends no
        // revision to order them by. One at a time is what makes the next
        // snapshot strictly newer than the last.
        let roster = OwnedSimRoster()

        let first = roster.beginRead()
        #expect(first != nil)
        #expect(roster.beginRead() == nil)

        roster.endRead(first ?? 0)
        #expect(roster.beginRead() != nil)
    }

    @Test
    func aSnapshotTakenBeforeAnOwnershipChangeIsRefused() {
        // The read was answered from a snapshot older than the attach, so
        // taking it would erase a sim DeviceTerm demonstrably owns.
        let roster = OwnedSimRoster()
        let inFlight = roster.beginRead() ?? 0

        roster.noteOwned(udid: simA, sessionId: sessionA, generation: 1)
        roster.record([], generation: 1, read: inFlight)
        roster.endRead(inFlight)
        roster.connectionReplaced(generation: 2)

        #expect(roster.beginRestore()?.claims.map(\.udid) == [simA])
    }

    @Test
    func anOwnershipChangeIsRememberedBeforeAnyPollCouldSeeIt() {
        // A sim owned and detached inside one poll interval has no pane left
        // to carry it and no read that ever saw it, so this is the only live,
        // trusted claim recovery can act on.
        let roster = OwnedSimRoster()

        roster.noteOwned(udid: simA.uppercased(), sessionId: sessionA, generation: 1)
        roster.connectionReplaced(generation: 2)

        #expect(
            roster.beginRestore()?.claims == [
                RestoredSimOwnership(udid: simA, sessionId: sessionA)
            ]
        )
    }

    @Test
    func aShutdownDropsTheClaimBeforeAnyPollCouldSeeIt() {
        // The daemon disowns the sim as part of the shutdown. A claim left
        // standing until the next poll is one recovery would re-assert, and a
        // fresh helper holds no attribution to conflict with and judges it on
        // current boot state alone, so another tool booting it in the meantime
        // would see deviceterm claim a device it no longer owns.
        let roster = OwnedSimRoster()
        poll(roster, [owned(simA, session: sessionA), owned(simB, session: sessionB)], generation: 1)

        roster.noteShutdown(udid: simA.uppercased())
        roster.connectionReplaced(generation: 2)

        #expect(roster.beginRestore()?.claims.map(\.udid) == [simB])
    }

    @Test
    func aSnapshotTakenBeforeAShutdownDoesNotPutTheClaimBack() {
        // The read was answered while the sim was still running, so taking it
        // would restore a claim the shutdown just retired.
        let roster = OwnedSimRoster()
        poll(roster, [owned(simA, session: sessionA)], generation: 1)
        let inFlight = roster.beginRead() ?? 0

        roster.noteShutdown(udid: simA)
        roster.record([owned(simA, session: sessionA)], generation: 1, read: inFlight)
        roster.endRead(inFlight)
        roster.connectionReplaced(generation: 2)

        #expect(roster.beginRestore()?.claims.isEmpty == true)
    }

    @Test
    func aPollIssuedAfterAnOwnershipChangeStillReplacesTheClaims() {
        // The claim isn't sticky. Once the helper has answered a read taken
        // after it, that answer is authoritative again, so a sim shut down
        // straight after being attached leaves the mirror.
        let roster = OwnedSimRoster()
        roster.noteOwned(udid: simA, sessionId: sessionA, generation: 1)

        poll(roster, [], generation: 1)
        roster.connectionReplaced(generation: 2)

        #expect(roster.beginRestore()?.claims.isEmpty == true)
    }

    @Test
    func aReplacementsFirstReadCannotEraseClaimsItNeverHeard() {
        // A claim can exist before any read does, and a replacement helper's
        // read can land during its handshake, before the reconnect
        // notification. A mirror believing nothing in particular would take
        // that empty roster and lose the sim.
        let roster = OwnedSimRoster()
        roster.noteOwned(udid: simA, sessionId: sessionA, generation: 1)

        poll(roster, [], generation: 2)
        roster.connectionReplaced(generation: 2)

        #expect(roster.beginRestore()?.claims.map(\.udid) == [simA])
    }

    @Test
    func aReadIsRefusedWhileARestoreIsOwed() {
        // Until the replacement has been told what it owns, any answer
        // describes a helper that hasn't heard the claims yet. The generation
        // check usually covers this, but only by implication; the invariant is
        // that nothing is believed while a restore is outstanding.
        let roster = OwnedSimRoster()
        poll(roster, [owned(simA, session: sessionA)], generation: 1)
        roster.connectionReplaced(generation: 2)

        // Tagged with the generation the mirror already trusts, so nothing but
        // the pending guard stands between this and the claims.
        poll(roster, [], generation: 1)

        #expect(roster.beginRestore()?.claims.map(\.udid) == [simA])
    }

    @Test
    func aSnapshotTakenBeforeRestorationIsRefused() {
        // A poll can snapshot the fresh helper's empty roster before
        // restoration re-asserts, then land after it settled. Taking that
        // answer would erase the claims restoration had just handed over, and
        // a second restart before the next poll would have nothing to hand
        // over at all.
        let roster = OwnedSimRoster()
        poll(roster, [owned(simA, session: sessionA)], generation: 1)
        roster.connectionReplaced(generation: 2)
        let inFlight = roster.beginRead() ?? 0

        roster.settle(generation: 2)
        roster.record([], generation: 2, read: inFlight)
        roster.endRead(inFlight)
        roster.connectionReplaced(generation: 3)

        #expect(roster.beginRestore()?.claims.map(\.udid) == [simA])
    }

    @Test
    func aReconnectOpensAWindowEvenWhenItsOwnReadArrivedFirst() {
        // Same race, other half: the replacement's read settles trust on its
        // generation, and a window measured against trust would then read the
        // reconnect as old news and never open one. Restoration would never
        // run for that helper.
        let roster = OwnedSimRoster()
        poll(roster, [owned(simA, session: sessionA)], generation: 2)

        roster.connectionReplaced(generation: 2)

        #expect(roster.isAwaitingRestore)
        #expect(roster.beginRestore()?.generation == 2)
    }
}
