// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import DaemonTestSupport
import Foundation
import Testing
@preconcurrency import XPC

// `session.setDisplayTitle` over the real XPC dispatch path with an
// injected `PeerValidator`. It is `.validatedGUI`-scoped, so the audit
// token alone admits the GUI (no session auth) and an unvalidated peer is
// refused. The UDS refusal is pinned separately in
// `SessionMethodsTests.setDisplayTitleRefusedOverUDS`.

private let validatedTitlePeer: PeerValidator = { _ in
    .production(peerTeamID: "TEST", peerBundleID: "test.host")
}
private let rejectedTitlePeer: PeerValidator = { _ in .rejected(reason: "test") }

private func displayTitleServer(
    manager: SessionManager,
    validator: @escaping PeerValidator
) -> XPCServer {
    let registry = MethodRegistry(
        handlers: [
            RPCMethod.sessionSetDisplayTitle.rawValue:
                .validatedGUI(SessionMethods.setDisplayTitle(using: manager)),
            RPCMethod.tabsList.rawValue:
                .daemonWide(SessionMethods.tabsList(using: manager))
        ],
        subscriptions: [:],
        provenance: TestPeerIdentity.xpcProvenance(manager)
    )
    let authValidator: AuthValidator = { try await manager.validate(sessionId: $0, capability: $1) }
    return XPCServer(
        methods: registry,
        authValidator: authValidator,
        peerValidator: validator
    )
}

private func sendTitle(
    envelopeId: UInt32,
    sessionId: String,
    title: String?,
    client: xpc_connection_t
) throws {
    sendRequest(
        envelopeId: envelopeId,
        method: RPCMethod.sessionSetDisplayTitle.rawValue,
        params: try JSONEncoder().encode(
            SessionSetDisplayTitleParams(sessionId: sessionId, title: title)
        ),
        client: client
    )
}

private func tabs(_ reply: xpc_object_t) throws -> [TabsListEntry] {
    let envelope = try decodeEnvelope(reply: reply)
    guard case let .result(bytes) = envelope.body else { return [] }
    return try JSONDecoder().decode([TabsListEntry].self, from: bytes)
}

@Test
func setDisplayTitleThenClearThroughTabsList() async throws {
    let manager = SessionManager()
    let session = try await manager.makeSessionState(name: "branch")
    let server = displayTitleServer(manager: manager, validator: validatedTitlePeer)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    // No session.authenticate first: the validated peer reaches the method
    // on its audit token alone.
    try sendTitle(envelopeId: 1, sessionId: session.id.uuidString, title: "vim foo", client: clientPair)
    let ack = try decodeEnvelope(reply: try await replyBox.awaitReply())
    if case let .error(error) = ack.body {
        Issue.record("validated-GUI setDisplayTitle should succeed; got error \(error.code)")
        return
    }

    sendRequest(envelopeId: 2, method: RPCMethod.tabsList.rawValue, client: clientPair)
    let listed = try tabs(try await replyBox.awaitReply())
    #expect(listed.first?.displayTitle == "vim foo")
    #expect(listed.first?.name == "branch")

    // The clear is a real operation: `tabs.list` drops back to the session
    // name rather than reporting the stale title.
    try sendTitle(envelopeId: 3, sessionId: session.id.uuidString, title: nil, client: clientPair)
    _ = try await replyBox.awaitReply()
    sendRequest(envelopeId: 4, method: RPCMethod.tabsList.rawValue, client: clientPair)
    let cleared = try tabs(try await replyBox.awaitReply())
    #expect(cleared.first?.displayTitle == nil)
    #expect(cleared.first?.name == "branch")
}

@Test
func setDisplayTitleForUnknownSessionRejected() async throws {
    let manager = SessionManager()
    let server = displayTitleServer(manager: manager, validator: validatedTitlePeer)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    try sendTitle(envelopeId: 1, sessionId: UUID().uuidString, title: "ghost", client: clientPair)
    let envelope = try decodeEnvelope(reply: try await replyBox.awaitReply())
    guard case let .error(error) = envelope.body else {
        Issue.record("unknown session must be rejected; got \(envelope.body)")
        return
    }
    // The usual `unauthorized` code, but not the shared "invalid sessionId
    // or cap" message: this method carries no capability, so naming one
    // would send whoever debugs it looking for a factor never sent.
    #expect(error.code == RPCMethodError.unauthorizedCode)
    #expect(error.message == "unknown sessionId")
}

@Test
func setDisplayTitleOverUnvalidatedXPCRefusedWithoutCaching() async throws {
    let manager = SessionManager()
    let session = try await manager.makeSessionState()
    let server = displayTitleServer(manager: manager, validator: rejectedTitlePeer)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    try sendTitle(envelopeId: 1, sessionId: session.id.uuidString, title: "spoof", client: clientPair)
    let envelope = try decodeEnvelope(reply: try await replyBox.awaitReply())
    guard case let .error(error) = envelope.body else {
        Issue.record("unvalidated XPC setDisplayTitle must be refused; got \(envelope.body)")
        return
    }
    #expect(error.code == RPCMethodError.roleViolationCode)
    #expect(await manager.displayTitle(session.id) == nil)
}
