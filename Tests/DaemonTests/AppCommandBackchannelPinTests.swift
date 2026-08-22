// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import DaemonTestSupport
import Foundation
import Testing

// The GUI back-channel (`app.commands` / `app.commandResult`) is
// `.validatedGUI`-scoped and pinned to one connection. Two properties:
//
//   1. Scope: no UDS caller reaches it, whatever its role. A rogue
//      local process can't evict the real GUI or read `tab.sendInput`
//      payloads in flight, because it can't subscribe at all.
//   2. Connection pin: even among validated peers, only the *current
//      subscriber connection* may deliver results, and only a teardown
//      for that connection clears the subscription, so a stale
//      `onCancel` can't unsubscribe the live GUI, and a second peer
//      can't forge results for the first.

// MARK: - Scope: refused over UDS for every role

@Test(
    arguments: [RPCMethod.appCommands, RPCMethod.appCommandResult],
    [nil, SessionRole.agent, SessionRole.automation] as [SessionRole?]
)
func backChannelRefusedOverUDS(method: RPCMethod, role: SessionRole?) async throws {
    let manager = SessionManager()
    let coord = AppCommandCoordinator()
    var created: CreatedSession?
    if let role {
        created = try await manager.createSession(label: nil, role: role)
    }
    let path = tempSocketPath(prefix: "deviceterm-backchannel")
    let server = try await startServer(
        path: path,
        sessionManager: manager,
        appCommandCoordinator: coord
    )
    defer { Task { await server.stop() } }

    let client: TestClient
    if let created {
        client = try TestClient.connectAuthenticated(to: path, as: created)
    } else {
        client = try TestClient.connect(to: path)
    }
    defer { client.close() }

    // The scope check runs in the dispatcher before the handler, so the
    // request body is irrelevant, an empty body reaches the refusal.
    try client.send(
        RPCEnvelope(id: 1, type: .request, method: method.rawValue, body: .empty)
    )
    let response = try client.receive()
    guard case let .error(error) = response.body else {
        Issue.record("expected \(method.rawValue) refused over UDS; got \(response.body)")
        return
    }
    #expect(error.code == RPCMethodError.scopeViolationCode)
    // The refusal happens at the scope gate: no subscription was ever
    // installed (the eviction path never ran).
    #expect(await coord.hasSubscriber == false)
}

// MARK: - Connection pin (coordinator-level)

/// Poll until the coordinator reports `expected` pending commands.
private func waitForPending(
    _ coord: AppCommandCoordinator,
    equals expected: Int,
    timeoutSeconds: Double = 2
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await coord.pendingCount == expected { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return false
}

@Test
func deliverResultFromNonSubscriberConnectionIsRefused() async {
    let coord = AppCommandCoordinator()
    let (stream, _) = await coord.subscribe(connectionId: 1)
    // Capture the published command's id so the wrong-connection
    // delivery targets a genuinely-pending command.
    let firstCommand = Task { () -> String in
        for await command in stream { return command.commandId }
        return ""
    }
    let publishTask = Task {
        await coord.publishAndAwait(
            kind: .tabInfo,
            originatingSessionId: nil,
            params: Data(#"{"tab":{"type":"current"}}"#.utf8),
            timeoutMs: 5_000
        )
    }
    let commandId = await firstCommand.value
    #expect(await waitForPending(coord, equals: 1))

    // A different connection cannot deliver: rejected, pending intact,
    // the live subscriber untouched.
    let refused = await coord.deliverResult(.ok(commandId: commandId), from: 999)
    #expect(!refused)
    #expect(await coord.pendingCount == 1)
    #expect(await coord.subscriberConnection == 1)

    // The real subscriber's delivery is accepted and resolves the call.
    let accepted = await coord.deliverResult(.ok(commandId: commandId), from: 1)
    #expect(accepted)
    if case .ok = await publishTask.value {} else {
        Issue.record("expected .ok after the subscriber delivered")
    }
}

@Test
func resubscribeFromNewConnectionEvictsAndFailsPending() async {
    let coord = AppCommandCoordinator()
    let (stream1, _) = await coord.subscribe(connectionId: 1)
    let dropper = Task { for await _ in stream1 { /* never acks */ } }
    let publishTask = Task {
        await coord.publishAndAwait(
            kind: .tabInfo,
            originatingSessionId: nil,
            params: Data(#"{"tab":{"type":"current"}}"#.utf8),
            timeoutMs: 5_000
        )
    }
    #expect(await waitForPending(coord, equals: 1))

    // The real GUI relaunches and re-subscribes on a new connection.
    // Last-wins: it takes over, and the prior subscriber's in-flight
    // command fails immediately rather than hanging until timeout.
    let (stream2, _) = await coord.subscribe(connectionId: 2)
    if case let .error(code, _) = await publishTask.value {
        #expect(code == "intent.guiUnavailable")
    } else {
        Issue.record("expected the evicted subscriber's command to fail")
    }
    #expect(await coord.hasSubscriber)
    #expect(await coord.subscriberConnection == 2)
    dropper.cancel()
    _ = stream2
}

@Test
func staleOnCancelFromEvictedConnectionDoesNotClearActiveSubscriber() async {
    // The latent-bug guard: an evicted connection's `onCancel` can land
    // *after* the new GUI subscribed. It must not tear the live
    // subscriber down: teardown is scoped to the current connection id.
    let coord = AppCommandCoordinator()
    let (_, onCancel1) = await coord.subscribe(connectionId: 1)
    let (stream2, _) = await coord.subscribe(connectionId: 2)

    // Fire connection 1's stale teardown now that connection 2 owns the
    // subscription.
    onCancel1()
    // `onCancel` hops through a Task onto the actor; let it run.
    try? await Task.sleep(nanoseconds: 30_000_000)

    #expect(await coord.hasSubscriber)
    #expect(await coord.subscriberConnection == 2)
    _ = stream2
}

@Test
func staleOnCancelFromSameConnectionResubscribeDoesNotClearActiveSubscriber() async {
    // The sharper case connection-id alone can't distinguish: the same
    // connection re-subscribes (its prior `onCancel` fires afterward,
    // carrying the same id). Teardown is matched on the subscription
    // *generation*, so the stale cancel is a no-op and the live
    // subscription survives.
    let coord = AppCommandCoordinator()
    let (_, onCancelOld) = await coord.subscribe(connectionId: 7)
    let (stream, _) = await coord.subscribe(connectionId: 7)

    onCancelOld()
    try? await Task.sleep(nanoseconds: 30_000_000)

    #expect(await coord.hasSubscriber)
    #expect(await coord.subscriberConnection == 7)
    _ = stream
}
