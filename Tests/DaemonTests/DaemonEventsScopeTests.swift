// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// `daemon.events` scoping, the two-layer contract:
//   1. Scope gate (`.session`): the dispatcher rejects an unauthenticated
//      connection with -32001 before the handler runs. Pinned here by the
//      registered scope; the generic gate turns a `.session` scope into the
//      -32001 reject for any unauthenticated caller.
//   2. Audience filter: the handler tags the subscription with the caller's
//      principal, so a `.session` sees only its own pane/session events plus
//      `.everyone` (device) events, while the GUI peer spans sessions. The
//      audience rule itself is unit-tested in EventBrokerTests; here it is
//      exercised through the real subscribe handler + a bound dispatch
//      context, so the principal derivation is covered too.

private func makeRegistry() -> MethodRegistry {
    DaemonMethods.defaultRegistry(
        sessionManager: SessionManager(),
        deviceCoordinator: DeviceCoordinator(),
        paneCoordinator: PaneCoordinator()
    )
}

/// Drive the real subscribe handler under a dispatch context authenticated
/// as `session`, returning its event stream.
private func subscribeAsSession(
    broker: EventBroker,
    session: SessionState
) async throws -> AsyncStream<MethodRegistry.SubscriptionEvent> {
    let handler = DaemonEventsMethods.subscribe(broker: broker)
    let context = DispatchPeerContext(transport: .uds, connectionId: 1)
        .withAuthenticatedSession(session)
    let result = try await DispatchPeerContext.$current.withValue(context) {
        try await handler(Data(), nil)
    }
    return result.events
}

private func firstEvent(
    _ stream: AsyncStream<MethodRegistry.SubscriptionEvent>
) async -> DaemonEvent? {
    var iterator = stream.makeAsyncIterator()
    guard let event = await iterator.next() else { return nil }
    return try? JSONDecoder().decode(DaemonEvent.self, from: event.params)
}

@Test
func daemonEventsIsSessionScoped() {
    // The -32001 property: a `.session` scope means the dispatcher's generic
    // scope gate rejects an unauthenticated connection before the handler
    // runs. Pin `.session` scope so unauthenticated callers cannot open the
    // event firehose.
    #expect(makeRegistry().scope(of: RPCMethod.daemonEvents.rawValue) == .session)
}

@Test
func sessionDoesNotSeeForeignPaneEvents() async throws {
    let broker = EventBroker()
    let session = try await SessionManager().createSession(label: nil).state
    let events = try await subscribeAsSession(broker: broker, session: session)

    // Publish a foreign-session pane event first, then an own-session one.
    // The foreign event is filtered by the audience rule, so the first event
    // that reaches this subscriber is the own one.
    await broker.publish(
        .paneStateChanged(paneId: "FOREIGN", udid: "U", state: "rendering", ts: "2026-05-30T18:00:00Z"),
        to: .session(UUID())
    )
    await broker.publish(
        .paneStateChanged(paneId: "OWN", udid: "U", state: "rendering", ts: "2026-05-30T18:00:01Z"),
        to: .session(session.id)
    )

    let received = await firstEvent(events)
    #expect(received?.paneId == "OWN")
}

@Test
func sessionSeesOwnPaneEvents() async throws {
    // Control: an own-session pane event reaches the subscriber.
    let broker = EventBroker()
    let session = try await SessionManager().createSession(label: nil).state
    let events = try await subscribeAsSession(broker: broker, session: session)

    let own = DaemonEvent.paneStateChanged(
        paneId: "OWN", udid: "U", state: "booting", ts: "2026-05-30T18:00:00Z"
    )
    await broker.publish(own, to: .session(session.id))
    #expect(await firstEvent(events) == own)
}

@Test
func deviceEventsReachEverySession() async throws {
    // Device booted/shutdown are `.everyone`, so a plain session subscriber
    // still sees them (a udid leaks nothing `device.list` doesn't).
    let broker = EventBroker()
    let session = try await SessionManager().createSession(label: nil).state
    let events = try await subscribeAsSession(broker: broker, session: session)

    let booted = DaemonEvent.deviceBooted(udid: "U", ts: "2026-05-30T18:00:00Z")
    await broker.publish(booted, to: .everyone)
    #expect(await firstEvent(events) == booted)
}
