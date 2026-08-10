// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// SessionManager × EventBroker: pins the publish wiring on the
// session lifecycle path. `createSession` publishes a
// `session.created` event; `closeSession` publishes `session.closed`.
//
// Uses an actual EventBroker + subscriber stream so the test
// exercises the cross-actor path (SessionManager publishes through
// `await eventBroker?.publish(...)`).

@Test
func createSessionPublishesSessionCreatedEvent() async throws {
    let broker = EventBroker()
    let manager = SessionManager(eventBroker: broker)
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)

    let created = try await manager.createSession(label: "alpha", name: "feature-x")
    let state = created.state

    var iterator = stream.makeAsyncIterator()
    let event = try #require(await iterator.next())
    #expect(event.type == DaemonEventType.sessionCreated)
    #expect(event.sessionId == state.id.uuidString)
    #expect(event.shortId == state.shortId)
    #expect(event.name == "feature-x")

    await broker.unsubscribe(subscriptionId)
}

@Test
func createSessionPublishesEvenWithoutName() async throws {
    let broker = EventBroker()
    let manager = SessionManager(eventBroker: broker)
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)

    _ = try await manager.makeSessionState(label: nil, name: nil)

    var iterator = stream.makeAsyncIterator()
    let event = try #require(await iterator.next())
    #expect(event.type == DaemonEventType.sessionCreated)
    #expect(event.name == nil)

    await broker.unsubscribe(subscriptionId)
}

@Test
func closeSessionPublishesSessionClosedEvent() async throws {
    let broker = EventBroker()
    let manager = SessionManager(eventBroker: broker)
    let created = try await manager.createSession(label: nil)
    let state = created.state
    let (subscriptionId, stream) = await broker.subscribe(as: .guiPeer)

    try await manager.closeSession(
        sessionId: state.id,
        capability: created.capability
    )

    var iterator = stream.makeAsyncIterator()
    let event = try #require(await iterator.next())
    #expect(event.type == DaemonEventType.sessionClosed)
    #expect(event.sessionId == state.id.uuidString)

    await broker.unsubscribe(subscriptionId)
}

@Test
func sessionManagerWorksWithoutEventBroker() async throws {
    // Default initializer keeps the broker nil. Tests that don't
    // care about events stay terse; production wires the broker.
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)
    let state = created.state
    #expect(!state.shortId.isEmpty)
    try await manager.closeSession(
        sessionId: state.id,
        capability: created.capability
    )
}
