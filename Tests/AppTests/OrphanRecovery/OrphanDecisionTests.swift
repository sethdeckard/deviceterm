// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

/// OrphanDecision: resolve dead-session candidates against the
/// daemon's ownership + Booted truth into live orphans vs. empty dirs.
struct OrphanDecisionTests {
    private func entry(
        _ udid: String,
        owner: String?,
        state: String = "Booted"
    ) -> DeviceListEntry {
        DeviceListEntry(
            udid: udid,
            name: "Sim-\(udid)",
            state: state,
            ownedBySession: owner
        )
    }

    @Test
    func manifestUDIDWithNoDaemonOwnerIsLive() {
        let candidate = DeadSessionCandidate(
            sessionId: "dead1",
            sessionDir: "/d1",
            manifestUDIDs: ["U1"]
        )
        let (live, dead) = OrphanDecision.resolve(
            deadCandidates: [candidate],
            deviceList: [entry("U1", owner: nil)]
        )
        #expect(dead.isEmpty)
        #expect(
            live == [
            OrphanRecord(
            sessionId: "dead1",
            sessionDir: "/d1",
            liveSims: [OrphanLiveSim(udid: "U1", displayName: "Sim-U1")]
        )
            ]
            )
    }

    @Test
    func manifestUDIDOwnedByLiveSessionIsNotAnOrphan() {
        // Daemon truth wins the tie: a sim re-adopted by another (live)
        // session no longer counts for this dead one.
        let candidate = DeadSessionCandidate(
            sessionId: "dead1",
            sessionDir: "/d1",
            manifestUDIDs: ["U1"]
        )
        let (live, dead) = OrphanDecision.resolve(
            deadCandidates: [candidate],
            deviceList: [entry("U1", owner: "liveSession")]
        )
        #expect(live.isEmpty)
        #expect(dead == ["/d1"])
    }

    @Test
    func daemonOwnedBootedSimIsOrphanWithoutManifest() {
        // The shim-boot path: booted+owned by the dead session, never
        // attached, so no manifest line, and still an orphan.
        let candidate = DeadSessionCandidate(
            sessionId: "dead1",
            sessionDir: "/d1",
            manifestUDIDs: []
        )
        let (live, dead) = OrphanDecision.resolve(
            deadCandidates: [candidate],
            deviceList: [entry("U2", owner: "dead1")]
        )
        #expect(dead.isEmpty)
        #expect(live.first?.liveSims.map(\.udid) == ["U2"])
    }

    @Test
    func manifestUDIDNotBootedIsSweptAsEmpty() {
        let candidate = DeadSessionCandidate(
            sessionId: "dead1",
            sessionDir: "/d1",
            manifestUDIDs: ["U1"]
        )
        let (live, dead) = OrphanDecision.resolve(
            deadCandidates: [candidate],
            deviceList: [entry("U1", owner: nil, state: "Shutdown")]
        )
        #expect(live.isEmpty)
        #expect(dead == ["/d1"])
    }

    @Test
    func manifestUDIDOwnedBySameDeadSessionIsLive() {
        let candidate = DeadSessionCandidate(
            sessionId: "dead1",
            sessionDir: "/d1",
            manifestUDIDs: ["U1"]
        )
        let (live, dead) = OrphanDecision.resolve(
            deadCandidates: [candidate],
            deviceList: [entry("U1", owner: "dead1")]
        )
        #expect(dead.isEmpty)
        #expect(live.first?.liveSims.map(\.udid) == ["U1"])
    }
}
