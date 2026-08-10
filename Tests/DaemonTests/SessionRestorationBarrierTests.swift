// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import DaemonTestSupport
import Foundation
import Testing

// The restoration barrier, driven end-to-end through the real UDS dispatcher.
// A fresh daemon starts empty and the GUI restores session state; until a
// validated GUI supplies its inventory, an UNKNOWN-session
// `session.authenticate` is the retryable `notReady` (-32002), not the terminal
// `unauthorized` (-32001), so an in-tab CLI keeps its bounded retry instead of
// pruning a valid credential.
// Once ANY restore batch (even empty) completes, an unknown session is
// terminally `unauthorized`. A known session with a WRONG cap is always hard:
// the barrier only reclassifies the unknown-session branch.

private func authenticateFrame(_ sessionId: String, _ cap: String) throws -> RPCEnvelope {
    RPCEnvelope(
        id: 1,
        type: .request,
        method: RPCMethod.sessionAuthenticate.rawValue,
        body: .params(
            try paramsBytes(SessionAuthenticateParams(sessionId: sessionId, cap: cap))
        )
    )
}

@Test
func unknownSessionAuthenticateIsRetryableWhilePendingRestoration() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    let path = tempSocketPath(prefix: "deviceterm-restore")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }
    let client = try TestClient.connect(to: path)
    defer { client.close() }

    try client.send(try authenticateFrame(UUID().uuidString, try Capability.random().token))
    guard case let .error(err) = try client.receive().body else {
        Issue.record("expected an error for an unknown session")
        return
    }
    // Retryable, not hard: the GUI may still restore this session.
    #expect(err.code == RPCMethodError.notReadyCode)
}

@Test
func unknownSessionAuthenticateIsHardAfterBarrierReleased() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    let path = tempSocketPath(prefix: "deviceterm-restore")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }
    let client = try TestClient.connect(to: path)
    defer { client.close() }

    // Release the barrier with an empty restore batch (the cold-start GUI's
    // "inventory is complete" signal).
    _ = try await manager.restoreBatch([], owner: nil, epoch: 1, revision: 1)

    try client.send(try authenticateFrame(UUID().uuidString, try Capability.random().token))
    guard case let .error(err) = try client.receive().body else {
        Issue.record("expected an error for an unknown session")
        return
    }
    // Now terminal: restoration finished and the session simply does not exist.
    #expect(err.code == RPCMethodError.unauthorizedCode)
}

@Test
func knownSessionWithWrongCapIsHardEvenWhilePending() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    let path = tempSocketPath(prefix: "deviceterm-restore")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }
    let client = try TestClient.connect(to: path)
    defer { client.close() }

    // A KNOWN session (created directly) but presented with the WRONG cap: the
    // barrier must NOT soften this to retryable. It reclassifies only the
    // unknown-session (`.notFound`) branch.
    let created = try await manager.createSession(label: nil)
    try client.send(try authenticateFrame(created.state.id.uuidString, try Capability.random().token))
    guard case let .error(err) = try client.receive().body else {
        Issue.record("expected an error for a wrong cap")
        return
    }
    #expect(err.code == RPCMethodError.unauthorizedCode)
}

@Test
func restoreBatchIsRefusedOverUDS() async throws {
    let manager = SessionManager(startsPendingRestoration: true)
    let path = tempSocketPath(prefix: "deviceterm-restore")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }
    let client = try TestClient.connect(to: path)
    defer { client.close() }

    // `.validatedGUI` scope: no UDS peer validates against the daemon signature,
    // so a CLI/shim can never restore a session.
    try client.send(
        RPCEnvelope(
            id: 1,
            type: .request,
            method: RPCMethod.sessionRestoreBatch.rawValue,
            body: .params(try paramsBytes(SessionRestoreBatchParams(sessions: [], revision: 1)))
        )
    )
    guard case let .error(err) = try client.receive().body else {
        Issue.record("restoreBatch over UDS must be refused")
        return
    }
    #expect(err.code == RPCMethodError.roleViolationCode)
    // And the barrier stays pending: a refused call can't release it.
    #expect(await manager.isRestorationComplete == false)
}
