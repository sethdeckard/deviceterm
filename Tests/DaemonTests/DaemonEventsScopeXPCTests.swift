// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import DaemonTestSupport
import Foundation
import Testing
@preconcurrency import XPC

// The `daemon.events` two-layer contract, exercised over the real XPC
// dispatch path (the privileged audience path a UDS harness can't reach):
//
//   A) A validated-but-*unauthenticated* GUI is rejected at the `.session`
//      scope gate with -32001. The gate has no notion of `.guiPeer`, only
//      "is there an authenticated session", so a validated peer that
//      hasn't authenticated one session yet cannot subscribe.
//   B) A validated GUI that *has* authenticated one session is promoted to
//      `.guiPeer` and receives another session's pane event: the
//      spans-every-session audience path, pinned end to end (not just the
//      handler-level derivation or a directly-supplied `.guiPeer`).

private func eventsServer(
    manager: SessionManager,
    broker: EventBroker,
    validator: @escaping PeerValidator
) -> XPCServer {
    let registry = MethodRegistry(
        subscriptions: [
            RPCMethod.daemonEvents.rawValue: .session(DaemonEventsMethods.subscribe(broker: broker))
        ],
        provenance: TestPeerIdentity.xpcProvenance(manager)
    )
    let authValidator: AuthValidator = { try await manager.validate(sessionId: $0, capability: $1) }
    return XPCServer(
        methods: registry,
        authValidator: authValidator,
        peerValidator: validator
    )
}

private let validatedGUI: PeerValidator = { _ in
    .production(peerTeamID: "TEST", peerBundleID: "test.host")
}

@Test
func validatedButUnauthenticatedGUIIsRejectedAtScopeGate() async throws {
    let server = eventsServer(manager: SessionManager(), broker: EventBroker(), validator: validatedGUI)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    // Subscribe without authenticating a session first.
    sendRequest(envelopeId: 1, method: RPCMethod.daemonEvents.rawValue, client: clientPair)
    let envelope = try decodeEnvelope(reply: try await replyBox.awaitReply())
    guard case let .error(error) = envelope.body else {
        Issue.record("a validated but unauthenticated GUI must be refused at the scope gate; got \(envelope.body)")
        return
    }
    #expect(error.code == RPCMethodError.unauthorizedCode)
}

@Test
func authenticatedValidatedGUISeesForeignSessionEvent() async throws {
    let manager = SessionManager()
    let broker = EventBroker()
    let created = try await manager.createSession(label: nil)
    let session = created.state
    let server = eventsServer(manager: manager, broker: broker, validator: validatedGUI)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    // Authenticate as `session`, so the connection carries both a validated
    // GUI verdict and an authenticated session → derives `.guiPeer`.
    let authParams = try JSONEncoder().encode(
        SessionAuthenticateParams(sessionId: session.id.uuidString, cap: created.capability.token)
    )
    sendRequest(
        envelopeId: 1,
        method: RPCMethod.sessionAuthenticate.rawValue,
        params: authParams,
        client: clientPair
    )
    _ = try await replyBox.awaitReply() // auth ack

    // Subscribe to daemon.events (past the scope gate now).
    sendRequest(envelopeId: 2, method: RPCMethod.daemonEvents.rawValue, client: clientPair)
    _ = try await replyBox.awaitReply() // subscription ack

    // Publish a pane event owned by a DIFFERENT session. A plain `.session`
    // subscriber would never see it; the GUI peer spans sessions.
    let foreign = DaemonEvent.paneStateChanged(
        paneId: "FOREIGN", udid: "U", state: "rendering", ts: "2026-05-30T18:00:00Z"
    )
    await broker.publish(foreign, to: .session(UUID()))

    let envelope = try decodeEnvelope(reply: try await replyBox.awaitReply())
    guard case let .params(data) = envelope.body else {
        Issue.record("expected a streamed event frame; got \(envelope.body)")
        return
    }
    #expect(try JSONDecoder().decode(DaemonEvent.self, from: data) == foreign)
}
