// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// EventBroker: daemon-wide pub/sub for DaemonEvents.
//
// Tests pin: fan-out to multiple subscribers, idempotent unsubscribe,
// continuation cleanup on stream drop, subscriber-count diagnostic.

@Test
func brokerStartsWithNoSubscribers() async {
    let broker = EventBroker()
    let count = await broker.subscriberCount
    #expect(count == 0)
}

@Test
func subscribeIncrementsCount() async {
    let broker = EventBroker()
    _ = await broker.subscribe(as: .guiPeer)
    let count = await broker.subscriberCount
    #expect(count == 1)
}

@Test
func publishFansOutToAllSubscribers() async {
    let broker = EventBroker()
    let (idA, streamA) = await broker.subscribe(as: .guiPeer)
    let (idB, streamB) = await broker.subscribe(as: .guiPeer)

    let event = DaemonEvent.paneStateChanged(
        paneId: "P",
        udid: "U",
        state: "rendering",
        ts: "2026-05-30T18:00:00Z"
    )
    await broker.publish(event, to: .everyone)

    // Each subscriber sees the same event.
    var iteratorA = streamA.makeAsyncIterator()
    var iteratorB = streamB.makeAsyncIterator()
    let receivedA = await iteratorA.next()
    let receivedB = await iteratorB.next()
    #expect(receivedA == event)
    #expect(receivedB == event)

    await broker.unsubscribe(idA)
    await broker.unsubscribe(idB)
}

@Test
func publishWithoutSubscribersIsNoOp() async {
    let broker = EventBroker()
    await broker.publish(
        .deviceBooted(udid: "U", ts: "2026-05-30T18:00:00Z"),
        to: .everyone
    )
    // No crash, no panic. Just nothing to do.
    let count = await broker.subscriberCount
    #expect(count == 0)
}

@Test
func unsubscribeIsIdempotent() async {
    let broker = EventBroker()
    let (subscriptionId, _) = await broker.subscribe(as: .guiPeer)
    await broker.unsubscribe(subscriptionId)
    // Second call is a no-op rather than a crash.
    await broker.unsubscribe(subscriptionId)
    let count = await broker.subscriberCount
    #expect(count == 0)
}

@Test
func unsubscribedStreamDoesNotReceiveSubsequentEvents() async {
    let broker = EventBroker()
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)
    await broker.unsubscribe(subscriptionId)
    // After unsubscribe, the stream is finished and `next()`
    // returns nil rather than blocking.
    var iterator = stream.makeAsyncIterator()
    let received = await iterator.next()
    #expect(received == nil)
}

@Test
func sessionSubscriberSeesOnlyItsOwnSessionEvents() async {
    // A `.session` subscriber receives a `.session(own)` event but not a
    // `.session(other)` one. The audience filter, not a self-`jq`, is what
    // scopes the stream.
    let broker = EventBroker()
    let own = UUID()
    let other = UUID()
    let (subscriptionId, stream) = await broker.subscribe(as: .session(own))

    let foreign = DaemonEvent.sessionCreated(
        sessionId: other.uuidString, shortId: "OTHER", name: nil, ts: "2026-05-30T18:00:00Z"
    )
    let mine = DaemonEvent.sessionCreated(
        sessionId: own.uuidString, shortId: "MINE", name: nil, ts: "2026-05-30T18:00:01Z"
    )
    await broker.publish(foreign, to: .session(other))
    await broker.publish(mine, to: .session(own))

    // The foreign event is filtered out, so the first delivered event is mine.
    var iterator = stream.makeAsyncIterator()
    let received = await iterator.next()
    #expect(received == mine)

    await broker.unsubscribe(subscriptionId)
}

@Test
func sessionSubscriberSeesEveryoneEvents() async {
    // `.everyone` (device booted/shutdown) reaches a `.session` subscriber.
    let broker = EventBroker()
    let (subscriptionId, stream) = await broker.subscribe(as: .session(UUID()))
    let event = DaemonEvent.deviceBooted(udid: "U", ts: "2026-05-30T18:00:00Z")
    await broker.publish(event, to: .everyone)

    var iterator = stream.makeAsyncIterator()
    let received = await iterator.next()
    #expect(received == event)

    await broker.unsubscribe(subscriptionId)
}

@Test
func guiPeerSeesForeignSessionEvents() async {
    // The validated GUI peer spans sessions: a `.session(other)` event
    // reaches it even though it is not that session.
    let broker = EventBroker()
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)
    let event = DaemonEvent.sessionCreated(
        sessionId: UUID().uuidString, shortId: "OTHER", name: nil, ts: "2026-05-30T18:00:00Z"
    )
    await broker.publish(event, to: .session(UUID()))

    var iterator = stream.makeAsyncIterator()
    let received = await iterator.next()
    #expect(received == event)

    await broker.unsubscribe(subscriptionId)
}

@Test
func publishOrderingPreservedAcrossEvents() async {
    let broker = EventBroker()
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)
    let first = DaemonEvent.paneStateChanged(
        paneId: "P",
        udid: "U",
        state: "booting",
        ts: "2026-05-30T18:00:00Z"
    )
    let second = DaemonEvent.paneStateChanged(
        paneId: "P",
        udid: "U",
        state: "rendering",
        ts: "2026-05-30T18:00:01Z"
    )
    await broker.publish(first, to: .everyone)
    await broker.publish(second, to: .everyone)

    var iterator = stream.makeAsyncIterator()
    let receivedFirst = await iterator.next()
    let receivedSecond = await iterator.next()
    #expect(receivedFirst == first)
    #expect(receivedSecond == second)

    await broker.unsubscribe(subscriptionId)
}
