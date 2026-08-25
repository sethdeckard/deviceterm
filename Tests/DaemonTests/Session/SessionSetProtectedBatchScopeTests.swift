// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import DaemonTestSupport
import Foundation
import Testing
@preconcurrency import XPC

// `session.setProtectedBatch` over the real XPC dispatch path with an
// injected `PeerValidator`. It is `.validatedGUI`-scoped, so the same
// audit-token anchor that gates the GUI back-channel gates this
// cross-session protection write: a signature-validated peer is admitted
// on its token alone (no session auth), an unvalidated one is refused,
// and a refused call mutates nothing. The UDS refusal is pinned
// separately in `SessionMethodsTests.setProtectedBatchRefusedOverUDS`.

private let validatedGUIPeer: PeerValidator = { _ in
    .production(peerTeamID: "TEST", peerBundleID: "test.host")
}
private let rejectedGUIPeer: PeerValidator = { _ in .rejected(reason: "test") }

private func batchResult(_ reply: xpc_object_t) -> SessionSetProtectedBatchResult? {
    guard let envelope = try? decodeEnvelope(reply: reply),
        case let .result(bytes) = envelope.body else { return nil }
    return try? JSONDecoder().decode(SessionSetProtectedBatchResult.self, from: bytes)
}

private func setProtectedBatchServer(
    manager: SessionManager,
    validator: @escaping PeerValidator
) -> XPCServer {
    let registry = MethodRegistry(
        handlers: [
            RPCMethod.sessionSetProtectedBatch.rawValue:
                .validatedGUI(SessionMethods.setProtectedBatch(using: manager))
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

@Test
func setProtectedBatchOverValidatedXPCFlipsTheWholeSet() async throws {
    let manager = SessionManager()
    let alpha = try await manager.makeSessionState(label: nil)
    let beta = try await manager.makeSessionState(label: nil)
    let server = setProtectedBatchServer(manager: manager, validator: validatedGUIPeer)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    // No session.authenticate first: the validated peer reaches the
    // method on its audit token alone.
    let body = try JSONEncoder().encode(
        SessionSetProtectedBatchParams(
            sessionIds: [alpha.id.uuidString, beta.id.uuidString],
            isProtected: true,
            revision: 1
        )
    )
    sendRequest(
        envelopeId: 1,
        method: RPCMethod.sessionSetProtectedBatch.rawValue,
        params: body,
        client: clientPair
    )
    let envelope = try decodeEnvelope(reply: try await replyBox.awaitReply())
    if case let .error(error) = envelope.body {
        Issue.record("validated-GUI setProtectedBatch should succeed; got error \(error.code)")
        return
    }
    #expect(await manager.isProtected(alpha.id))
    #expect(await manager.isProtected(beta.id))
}

@Test
func setProtectedBatchLaterConnectionEpochDominatesEarlier() async throws {
    // The ordering epoch is the SERVER-derived XPC connection id. A
    // replacement connection (accepted later) gets a strictly higher epoch,
    // so its write dominates the earlier connection's even at a LOWER
    // revision, and a late write from the OLD connection is rejected. This
    // exercises the connectionId-as-epoch wiring through two real
    // connections (the SessionManager unit test injects epochs directly).
    let manager = SessionManager()
    let session = try await manager.makeSessionState(label: nil)
    let server = setProtectedBatchServer(manager: manager, validator: validatedGUIPeer)
    let (listener, peerA) = makeAnonymousPair()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    let replyA = ReplyBox()
    setupClient(peerA, replyBox: replyA)

    // Connection A sets it protected at a HIGH revision.
    sendRequest(
        envelopeId: 1,
        method: RPCMethod.sessionSetProtectedBatch.rawValue,
        params: try JSONEncoder().encode(SessionSetProtectedBatchParams(
            sessionIds: [session.id.uuidString], isProtected: true, revision: 100
        )),
        client: peerA
    )
    let resultA1 = try #require(batchResult(try await replyA.awaitReply()))
    #expect(resultA1.applied)
    #expect(await manager.isProtected(session.id))

    // A replacement connection B (later accept → higher epoch) sets it
    // UNPROTECTED at a LOW revision, dominates on epoch alone.
    let peerB = xpc_connection_create_from_endpoint(xpc_endpoint_create(listener))
    let replyB = ReplyBox()
    setupClient(peerB, replyBox: replyB)
    sendRequest(
        envelopeId: 2,
        method: RPCMethod.sessionSetProtectedBatch.rawValue,
        params: try JSONEncoder().encode(SessionSetProtectedBatchParams(
            sessionIds: [session.id.uuidString], isProtected: false, revision: 1
        )),
        client: peerB
    )
    let resultB1 = try #require(batchResult(try await replyB.awaitReply()))
    #expect(resultB1.applied)                               // higher epoch wins
    #expect(await manager.isProtected(session.id) == false)

    // A LATE write from the OLD connection A, even at a higher revision, is
    // rejected: its epoch no longer dominates.
    sendRequest(
        envelopeId: 3,
        method: RPCMethod.sessionSetProtectedBatch.rawValue,
        params: try JSONEncoder().encode(SessionSetProtectedBatchParams(
            sessionIds: [session.id.uuidString], isProtected: true, revision: 999
        )),
        client: peerA
    )
    let resultA2 = try #require(batchResult(try await replyA.awaitReply()))
    #expect(resultA2.applied == false)                     // stale: old epoch
    #expect(await manager.isProtected(session.id) == false)   // stays unprotected
}

@Test
func setProtectedBatchUnknownIdRejectedThroughRealHandler() async throws {
    // Validation runs through the real dispatch path (not just a
    // SessionManager unit test): a batch naming one live and one unknown
    // session is refused all-or-none, and the live session is left
    // untouched, so a rejection is unambiguously "nothing committed."
    let manager = SessionManager()
    let live = try await manager.makeSessionState(label: nil)
    let server = setProtectedBatchServer(manager: manager, validator: validatedGUIPeer)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    let body = try JSONEncoder().encode(
        SessionSetProtectedBatchParams(
            sessionIds: [live.id.uuidString, UUID().uuidString],
            isProtected: true,
            revision: 1
        )
    )
    sendRequest(
        envelopeId: 1,
        method: RPCMethod.sessionSetProtectedBatch.rawValue,
        params: body,
        client: clientPair
    )
    let envelope = try decodeEnvelope(reply: try await replyBox.awaitReply())
    guard case .error = envelope.body else {
        Issue.record("unknown id in batch must be rejected; got \(envelope.body)")
        return
    }
    #expect(await manager.isProtected(live.id) == false)
}

@Test
func setProtectedBatchOverUnvalidatedXPCRefusedWithoutMutation() async throws {
    let manager = SessionManager()
    let alpha = try await manager.makeSessionState(label: nil)
    let server = setProtectedBatchServer(manager: manager, validator: rejectedGUIPeer)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    let body = try JSONEncoder().encode(
        SessionSetProtectedBatchParams(sessionIds: [alpha.id.uuidString], isProtected: true, revision: 1)
    )
    sendRequest(
        envelopeId: 1,
        method: RPCMethod.sessionSetProtectedBatch.rawValue,
        params: body,
        client: clientPair
    )
    let envelope = try decodeEnvelope(reply: try await replyBox.awaitReply())
    guard case let .error(error) = envelope.body else {
        Issue.record("unvalidated XPC setProtectedBatch must be refused; got \(envelope.body)")
        return
    }
    #expect(error.code == RPCMethodError.scopeViolationCode)
    #expect(await manager.isProtected(alpha.id) == false)
}
