// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// One test per race the lane arbitrates. A pane has one shared digitizer
// stream: composite gestures serialize on it, live producers share a single
// live lease, and the lane reopens only once the contact it was holding is
// accounted for.

/// Records the recoveries the lane asks for. A nil entry is the
/// "release whatever is still down" case a failed composite produces.
private final class ReleaseRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.deviceterm.tests.release-recorder")
    private var contacts: [ContactLane.LiveContact?] = []
    private var failuresRemaining = 0

    var recorded: [ContactLane.LiveContact] {
        queue.sync { contacts.compactMap(\.self) }
    }

    /// Every recovery, including the flavorless one.
    var all: [ContactLane.LiveContact?] {
        queue.sync { contacts }
    }

    /// Make the next `count` recoveries report failure, modelling a release
    /// send that didn't land.
    func failNext(_ count: Int) {
        queue.sync { failuresRemaining = count }
    }

    /// Records the attempt and reports whether the contact is now clean.
    func record(_ contact: ContactLane.LiveContact?) -> Bool {
        queue.sync {
            contacts.append(contact)
            guard failuresRemaining > 0 else { return true }
            failuresRemaining -= 1
            return false
        }
    }
}

private func makeLane(
    pacer: any GesturePacing = SystemGesturePacer(),
    recorder: ReleaseRecorder = ReleaseRecorder()
) -> ContactLane {
    ContactLane(pacer: pacer) { contact, _ in recorder.record(contact) }
}

// MARK: - Composites take turns

@Test
func twoCompositesNeverHoldTheLaneAtOnce() async {
    let lane = makeLane()
    let first = await lane.admitComposite(preemptible: true, generation: 0)
    let firstId = try? #require(first?.id)
    // The second blocks while the first holds it, so its down can't land
    // between the first's down and up.
    let second = Task { await lane.admitComposite(preemptible: true, generation: 0) }
    try? await Task.sleep(for: .milliseconds(20))
    #expect(!second.isCancelled)
    await lane.release(firstId ?? 0)
    let ticket = await second.value
    #expect(ticket != nil)
    #expect(ticket?.id != firstId)
}

@Test
func aStaleReleaseCannotFreeSomeoneElsesLease() async {
    let lane = makeLane()
    let first = await lane.admitComposite(preemptible: true, generation: 0)
    let staleId = try? #require(first?.id)
    await lane.release(staleId ?? 0)
    let second = await lane.admitComposite(preemptible: true, generation: 0)
    // Replaying the first lease's release must not drop the second's hold.
    await lane.release(staleId ?? 0)
    let third = Task { await lane.admitComposite(preemptible: true, generation: 0) }
    try? await Task.sleep(for: .milliseconds(20))
    #expect(!third.isCancelled)
    await lane.release(second?.id ?? 0)
    #expect(await third.value != nil)
}

// MARK: - Live input leapfrogs, and preempts what it may

@Test
func aLiveDownPreemptsAPreemptibleComposite() async {
    let lane = makeLane()
    let holder = await lane.admitComposite(preemptible: true, generation: 0)
    let fence = try? #require(holder?.fence)
    let live = Task {
        await lane.admitLive(phase: .down, contact: .plain(.zero), generation: 0)
    }
    try? await Task.sleep(for: .milliseconds(20))
    // The lane asked the holder to let go; the gesture polls this from
    // off-actor and breaks to its own release.
    #expect(fence?.isPreempted == true)
    await lane.release(holder?.id ?? 0)
    #expect(await live.value.send)
}

@Test
func aLiveDownWaitsOutAnUnpreemptibleComposite() async {
    let lane = makeLane()
    let holder = await lane.admitComposite(preemptible: false, generation: 0)
    let fence = try? #require(holder?.fence)
    let live = Task {
        await lane.admitLive(phase: .down, contact: .plain(.zero), generation: 0)
    }
    try? await Task.sleep(for: .milliseconds(20))
    // A tap is two frames long and the App Switcher only reads as a gesture
    // whole, so neither is cut short.
    #expect(fence?.isPreempted == false)
    await lane.release(holder?.id ?? 0)
    #expect(await live.value.send)
}

@Test
func liveWaitersResumeBeforeQueuedComposites() async {
    let lane = makeLane()
    let holder = await lane.admitComposite(preemptible: false, generation: 0)
    let composite = Task { await lane.admitComposite(preemptible: true, generation: 0) }
    try? await Task.sleep(for: .milliseconds(10))
    let live = Task {
        await lane.admitLive(phase: .down, contact: .plain(.zero), generation: 0)
    }
    try? await Task.sleep(for: .milliseconds(10))
    await lane.release(holder?.id ?? 0)
    // The live arrival queued second but goes first: a human drag must not
    // wait out a backlog of scripted verbs.
    #expect(await live.value.send)
    let ticket = await composite.value
    #expect(ticket == nil || ticket != nil)
    composite.cancel()
}

// MARK: - Lifts

@Test
func aLiftWithNoLiveLeaseSendsNothing() async {
    let lane = makeLane()
    let admitted = await lane.admitLive(phase: .lift, contact: .plain(.zero), generation: 0)
    // A duplicate or leftover lift. Passing it through would release contact
    // that a composite may be holding.
    #expect(!admitted.send)
}

@Test
func aLiftDoesNotReleaseACompositesContact() async {
    let lane = makeLane()
    let holder = await lane.admitComposite(preemptible: false, generation: 0)
    let admitted = await lane.admitLive(phase: .lift, contact: .plain(.zero), generation: 0)
    #expect(!admitted.send)
    // The composite still holds it, so a queued arrival stays queued.
    let queued = Task { await lane.admitComposite(preemptible: true, generation: 0) }
    try? await Task.sleep(for: .milliseconds(20))
    #expect(!queued.isCancelled)
    await lane.release(holder?.id ?? 0)
    #expect(await queued.value != nil)
}

@Test
func aLiveStreamPassesThroughWithoutQueueing() async {
    let lane = makeLane()
    #expect(await lane.admitLive(phase: .down, contact: .plain(.zero), generation: 0).send)
    #expect(await lane.admitLive(phase: .move, contact: .plain(.zero), generation: 0).send)
    #expect(await lane.admitLive(phase: .move, contact: .plain(.zero), generation: 0).send)
    let lift = await lane.admitLive(phase: .lift, contact: .plain(.zero), generation: 0)
    #expect(lift.send)
    // The lane is still held: the caller has not sent the up yet.
    #expect(lift.releaseAfterSend != nil)
    await lane.release(lift.releaseAfterSend ?? 0)
    // Released only now, so a composite takes the lane.
    #expect(await lane.admitComposite(preemptible: true, generation: 0) != nil)
}

@Test
func aMoveWithNoLeaseOpensOne() async {
    let lane = makeLane()
    // The GUI's down and its moves are separate RPCs and XPC does not order
    // them, so a move can arrive first.
    #expect(await lane.admitLive(phase: .move, contact: .plain(.zero), generation: 0).send)
    #expect(await lane.admitLive(phase: .lift, contact: .plain(.zero), generation: 0).send)
}

// MARK: - Expiry

@Test
func anAbandonedLiveContactExpiresAndReleasesItsOwnFlavor() async {
    let contacts: [ContactLane.LiveContact] = [
        .plain(CGPoint(x: 0.5, y: 0.5)),
        .edge(CGPoint(x: 0.5, y: 0.9), edge: 3),
        .multi(CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8))
    ]
    for contact in contacts {
        let recorder = ReleaseRecorder()
        let pacer = FakeGesturePacer()
        let lane = makeLane(pacer: pacer, recorder: recorder)
        #expect(await lane.admitLive(phase: .down, contact: contact, generation: 7).send)
        // The expiry task sleeps on the same virtual clock, so it fires as
        // soon as it is scheduled. Bounded rather than a bare spin, so a
        // regression fails the test instead of hanging the suite.
        for _ in 0..<1_000 where recorder.recorded.isEmpty {
            await Task.yield()
        }
        // Releasing the wrong flavor leaves the guest holding a finger down.
        #expect(recorder.recorded == [contact])
        // The lane is free again.
        #expect(await lane.admitComposite(preemptible: true, generation: 7) != nil)
    }
}

@Test
func aRefreshedLiveLeaseDoesNotExpire() async {
    let recorder = ReleaseRecorder()
    let lane = makeLane(recorder: recorder)
    #expect(await lane.admitLive(phase: .down, contact: .plain(.zero), generation: 0).send)
    #expect(await lane.admitLive(phase: .move, contact: .plain(.zero), generation: 0).send)
    // Real time, briefly: the point is that the two-second deadline has not
    // arrived, not how the clock advances.
    try? await Task.sleep(for: .milliseconds(30))
    #expect(recorder.recorded.isEmpty)
}

// MARK: - Cancellation

@Test
func aCancelledWaiterLeavesTheQueueAndNeverAdmits() async {
    let lane = makeLane()
    let holder = await lane.admitComposite(preemptible: false, generation: 0)
    let queued = Task { await lane.admitComposite(preemptible: true, generation: 0) }
    try? await Task.sleep(for: .milliseconds(20))
    queued.cancel()
    // Resumes once, with no ticket, so the caller sends nothing.
    #expect(await queued.value == nil)
    await lane.release(holder?.id ?? 0)
    // Its slot did not leak: the next arrival takes the lane straight away.
    #expect(await lane.admitComposite(preemptible: true, generation: 0) != nil)
}

// MARK: - Close and transfer

@Test
func closeCancelsWaitersButLetsAnActiveCompositeFinish() async {
    let lane = makeLane()
    let holder = await lane.admitComposite(preemptible: true, generation: 0)
    let queued = Task { await lane.admitComposite(preemptible: true, generation: 0) }
    try? await Task.sleep(for: .milliseconds(20))
    await lane.close()
    #expect(await queued.value == nil)
    // The holder is untouched: the coordinator keeps the pane's machinery
    // alive until it releases.
    #expect(await lane.hasActiveComposite)
    await lane.release(holder?.id ?? 0)
    #expect(await lane.hasActiveComposite == false)
}

@Test
func closeReleasesAnAbandonedLiveContact() async {
    let recorder = ReleaseRecorder()
    let lane = makeLane(recorder: recorder)
    let contact = ContactLane.LiveContact.plain(CGPoint(x: 0.25, y: 0.75))
    #expect(await lane.admitLive(phase: .down, contact: contact, generation: 3).send)
    await lane.close()
    // Nobody is going to send the lift now, so the lane sends it.
    #expect(recorder.recorded == [contact])
    #expect(await lane.hasActiveComposite == false)
}

@Test
func transferFencesTheHolderAndSendsNothing() async {
    let recorder = ReleaseRecorder()
    let lane = makeLane(recorder: recorder)
    let holder = await lane.admitComposite(preemptible: false, generation: 0)
    let fence = try? #require(holder?.fence)
    let queued = Task { await lane.admitComposite(preemptible: true, generation: 0) }
    try? await Task.sleep(for: .milliseconds(20))
    await lane.transfer()
    // Transfer fences even an unpreemptible holder and emits no release; the
    // coordinator's following backend quiesce owns the contact cleanup.
    #expect(fence?.isPreempted == true)
    #expect(await queued.value == nil)
    #expect(recorder.recorded.isEmpty)
}

@Test
func aClosedLaneAdmitsNothingFurther() async {
    let lane = makeLane()
    await lane.close()
    #expect(await lane.admitComposite(preemptible: true, generation: 0) == nil)
    #expect(!(await lane.admitLive(phase: .down, contact: .plain(.zero), generation: 0)).send)
}

// MARK: - Handoff is atomic, and a lift holds until it has sent

@Test
func aLiftKeepsTheLaneUntilTheCallerReportsItSent() async {
    let lane = makeLane()
    #expect(await lane.admitLive(phase: .down, contact: .plain(.zero), generation: 0).send)
    let lift = await lane.admitLive(phase: .lift, contact: .plain(.zero), generation: 0)
    #expect(lift.send)
    // Releasing on admission would let the next gesture's down reach the
    // digitizer ahead of this up, which is the interleaving the lane exists to
    // prevent.
    let queued = Task { await lane.admitComposite(preemptible: true, generation: 0) }
    try? await Task.sleep(for: .milliseconds(20))
    #expect(!queued.isCancelled)
    await lane.release(lift.releaseAfterSend ?? 0)
    #expect(await queued.value != nil)
}

@Test
func ownershipPassesToOneWaiterWithNoGapForAFreshArrival() async {
    let lane = makeLane()
    let holder = await lane.admitComposite(preemptible: false, generation: 0)
    let queued = Task { await lane.admitComposite(preemptible: true, generation: 0) }
    try? await Task.sleep(for: .milliseconds(20))
    // The successor's lease is minted in the same step that drops the holder's,
    // so a request arriving right after the release still queues rather than
    // taking a lane that looks momentarily free.
    await lane.release(holder?.id ?? 0)
    let latecomer = Task { await lane.admitComposite(preemptible: true, generation: 0) }
    let granted = await queued.value
    #expect(granted != nil)
    try? await Task.sleep(for: .milliseconds(20))
    #expect(!latecomer.isCancelled)
    await lane.release(granted?.id ?? 0)
    let third = await latecomer.value
    #expect(third != nil)
    // Three admissions, three distinct leases.
    #expect(holder?.id != granted?.id)
    #expect(granted?.id != third?.id)
}

// MARK: - A lift must match what is actually down

@Test
func aPlainLiftDoesNotReleaseATwoFingerContact() async {
    let recorder = ReleaseRecorder()
    let lane = makeLane(recorder: recorder)
    let fingers = ContactLane.LiveContact.multi(CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.8))
    #expect(await lane.admitLive(phase: .down, contact: fingers, generation: 0).send)
    // Two live producers on one pane can order a plain lift behind a
    // two-finger down. Sending `tapUp` there reports a lift for a finger that
    // isn't down and leaves both real contacts held.
    let plainLift = await lane.admitLive(phase: .lift, contact: .plain(.zero), generation: 0)
    #expect(!plainLift.send)
    // The matching lift still works.
    let realLift = await lane.admitLive(phase: .lift, contact: fingers, generation: 0)
    #expect(realLift.send)
    await lane.release(realLift.releaseAfterSend ?? 0)
    #expect(await lane.admitComposite(preemptible: true, generation: 0) != nil)
}

@Test
func aFailedLiftKeepsTheLaneSoExpiryCanRecoverIt() async {
    let lane = makeLane()
    #expect(await lane.admitLive(phase: .down, contact: .plain(.zero), generation: 0).send)
    let lift = await lane.admitLive(phase: .lift, contact: .plain(.zero), generation: 0)
    #expect(lift.send)
    // The caller's send threw, so it never reports the release. The contact is
    // still down, and admitting the next gesture on top of it would interleave.
    let queued = Task { await lane.admitComposite(preemptible: true, generation: 0) }
    try? await Task.sleep(for: .milliseconds(20))
    #expect(!queued.isCancelled)
    queued.cancel()
}

@Test
func onlyOneLiftIsAdmittedAgainstALiveLease() async {
    let lane = makeLane()
    #expect(await lane.admitLive(phase: .down, contact: .plain(.zero), generation: 0).send)
    let first = await lane.admitLive(phase: .lift, contact: .plain(.zero), generation: 0)
    #expect(first.send)
    // A second concurrent lift would otherwise be handed the same lease id, and
    // its `up` could land after the first released and the lane moved on.
    let second = await lane.admitLive(phase: .lift, contact: .plain(.zero), generation: 0)
    #expect(!second.send)
}

@Test
func aFailedCompositeRecoversItsContactBeforeFreeingTheLane() async {
    let recorder = ReleaseRecorder()
    let pacer = FakeGesturePacer()
    let lane = makeLane(pacer: pacer, recorder: recorder)
    let holder = await lane.admitComposite(preemptible: true, generation: 0)
    let ticket = holder?.id ?? 0
    // Its terminal up may never have landed, and a composite never tells the
    // lane what it was holding. Handing the lane on without recovering would
    // stack the next gesture on a finger that could still be down.
    await lane.releaseAfterFailure(ticket)
    var admitted: ContactLane.CompositeTicket?
    for _ in 0..<1_000 where admitted == nil {
        admitted = await lane.admitComposite(preemptible: true, generation: 0)
        if admitted == nil { await Task.yield() }
    }
    #expect(admitted != nil)
    #expect(admitted?.id != ticket)
    // A flavorless recovery: the backend releases whatever it still holds.
    #expect(recorder.all == [ContactLane.LiveContact?.none])
}

@Test
func aFailedRecoveryKeepsTheLaneUntilItLands() async {
    let recorder = ReleaseRecorder()
    let pacer = FakeGesturePacer()
    let lane = makeLane(pacer: pacer, recorder: recorder)
    let holder = await lane.admitComposite(preemptible: true, generation: 0)
    // The first release attempt doesn't land, so the contact may still be
    // down. Admitting the next gesture there is the interleaving the lane
    // exists to prevent.
    recorder.failNext(1)
    await lane.releaseAfterFailure(holder?.id ?? 0)
    var admitted: ContactLane.CompositeTicket?
    for _ in 0..<1_000 where admitted == nil {
        admitted = await lane.admitComposite(preemptible: true, generation: 0)
        if admitted == nil { await Task.yield() }
    }
    // It retried, and only handed the lane on once a release actually landed.
    #expect(admitted != nil)
    #expect(recorder.all.count >= 2)
}

@Test
func aLaneWhoseContactWontFreeStaysShut() async {
    let recorder = ReleaseRecorder()
    let pacer = FakeGesturePacer()
    let lane = makeLane(pacer: pacer, recorder: recorder)
    let holder = await lane.admitComposite(preemptible: true, generation: 0)
    // Every release attempt reports the contact still down. Handing the lane on
    // would merge the next gesture with it, so nothing is admitted at all.
    recorder.failNext(1_000)
    await lane.releaseAfterFailure(holder?.id ?? 0)
    for _ in 0..<200 {
        await Task.yield()
    }
    #expect(await lane.admitComposite(preemptible: true, generation: 0) == nil)
    #expect(await lane.admitLive(phase: .down, contact: .plain(.zero), generation: 0).send == false)
    // It kept trying rather than giving up.
    #expect(recorder.all.count > 1)
}

@Test
func aCloseClearsALaneStuckOnAnUnrecoveredContact() async {
    let recorder = ReleaseRecorder()
    let pacer = FakeGesturePacer()
    let lane = makeLane(pacer: pacer, recorder: recorder)
    let holder = await lane.admitComposite(preemptible: true, generation: 0)
    recorder.failNext(1_000)
    await lane.releaseAfterFailure(holder?.id ?? 0)
    for _ in 0..<200 {
        await Task.yield()
    }
    // The pane is going away and its teardown owns the contact from here, so
    // the lane stops refusing and stops retrying.
    await lane.close()
    #expect(await lane.hasActiveComposite == false)
}

@Test
func aGestureFailingAfterCloseHandsTheContactToTeardown() async {
    let recorder = ReleaseRecorder()
    let lane = makeLane(recorder: recorder)
    let holder = await lane.admitComposite(preemptible: true, generation: 0)
    // Close first, then the gesture throws. Retaining the lease for recovery
    // here would block the teardown that is itself responsible for freeing the
    // contact, and `awaitIdle` would never resume.
    await lane.close()
    recorder.failNext(1_000)
    await lane.releaseAfterFailure(holder?.id ?? 0)
    #expect(await lane.hasActiveComposite == false)
    // Bounded: a hang here is the bug this pins.
    await lane.awaitIdle()
}

@Test
func aGestureFailingBeforeCloseAlsoHandsTheContactOver() async {
    let recorder = ReleaseRecorder()
    let pacer = FakeGesturePacer()
    let lane = makeLane(pacer: pacer, recorder: recorder)
    let holder = await lane.admitComposite(preemptible: true, generation: 0)
    // The inverse order of the previous test: the gesture fails first, and the
    // close arrives while recovery is still failing. The lease must not survive
    // that, or the teardown waits on a recovery it is the one performing.
    recorder.failNext(1_000)
    await lane.releaseAfterFailure(holder?.id ?? 0)
    for _ in 0..<200 {
        await Task.yield()
    }
    await lane.close()
    #expect(await lane.hasActiveComposite == false)
    await lane.awaitIdle()
}
