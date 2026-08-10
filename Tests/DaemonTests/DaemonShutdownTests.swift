// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import DaemonTestSupport
import Foundation
import Testing
@preconcurrency import XPC

// `daemon.shutdown` is `.validatedGUI`, XPC-only. Its sole production use is
// terminating an incompatible old helper after a definite update-related wire
// mismatch. These tests pin the trust rule: only a signature-validated XPC peer
// reaches the handler (and fires the terminate trigger); every UDS caller
// (whatever its role, capability, or orchestration grant) is refused, as is an
// unvalidated or stably-invalid XPC peer. A transient validation failure is
// fail-closed for the attempt but retryable, and never fires the trigger
// prematurely. Capability advertising must agree with dispatch.

private actor ShutdownRecorder {
    private(set) var fired = 0
    func record() { fired += 1 }
}

private let validatedGUIPeer: PeerValidator = { _ in
    .production(peerTeamID: "TEST", peerBundleID: "test.host")
}
private let rejectedPeer: PeerValidator = { _ in .rejected(reason: "test") }

/// A registry whose `daemon.shutdown` fires `recorder`. No `authValidator`, so
/// no session/provenance is needed: `.validatedGUI` authorizes on the audit
/// token alone.
private func shutdownRegistry(recorder: ShutdownRecorder) -> MethodRegistry {
    DaemonMethods.defaultRegistry(
        sessionManager: SessionManager(),
        deviceCoordinator: DeviceCoordinator(),
        paneCoordinator: PaneCoordinator(),
        shutdownTrigger: { await recorder.record() }
    )
}

private func shutdownXPCServer(
    recorder: ShutdownRecorder,
    validator: @escaping PeerValidator
) -> XPCServer {
    XPCServer(methods: shutdownRegistry(recorder: recorder), peerValidator: validator)
}

// MARK: - 1. Validated GUI XPC reaches the handler and fires the trigger once

@Test
func daemonShutdownReachesValidatedGUIPeerAndFiresTriggerOnce() async throws {
    let recorder = ShutdownRecorder()
    let server = shutdownXPCServer(recorder: recorder, validator: validatedGUIPeer)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    sendRequest(envelopeId: 1, method: RPCMethod.daemonShutdown.rawValue, client: clientPair)
    let reply = try decodeEnvelope(reply: try await replyBox.awaitReply())
    guard case let .result(bytes) = reply.body else {
        Issue.record("expected {ok} result, got \(reply.body)")
        return
    }
    let ack = try JSONDecoder().decode(DaemonMethods.ShutdownResponse.self, from: bytes)
    #expect(ack.success)

    // The trigger fires from a detached task after `shutdownAckGraceMs`; wait
    // for it, then confirm it fired EXACTLY once.
    let fired = try await poll(timeout: 2.0) { await recorder.fired == 1 }
    #expect(fired)
    #expect(await recorder.fired == 1)
}

// MARK: - 5. A stably-invalid XPC peer is refused and never fires the trigger

@Test
func daemonShutdownRefusedForStablyInvalidXPCPeer() async throws {
    let recorder = ShutdownRecorder()
    let server = shutdownXPCServer(recorder: recorder, validator: rejectedPeer)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    sendRequest(envelopeId: 1, method: RPCMethod.daemonShutdown.rawValue, client: clientPair)
    let reply = try decodeEnvelope(reply: try await replyBox.awaitReply())
    guard case let .error(err) = reply.body else {
        Issue.record("expected refusal, got \(reply.body)")
        return
    }
    #expect(err.code == RPCMethodError.roleViolationCode)
    // Past the ack grace: the handler never ran, so the trigger never fired.
    try await Task.sleep(nanoseconds: (DaemonMethods.shutdownAckGraceMs + 200) * 1_000_000)
    #expect(await recorder.fired == 0)
}

// MARK: - 6. Transient validation is fail-closed but retryable; no premature fire

/// Validator that is `.unavailable` on its first call (a transient identity
/// read failure) and stable `.production` afterward.
private final class FlakyValidator: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var validator: PeerValidator {
        { _ in
            self.lock.lock(); defer { self.lock.unlock() }
            self.calls += 1
            return self.calls == 1
                ? .unavailable(reason: "first walk flaky")
                : .production(peerTeamID: "TEST", peerBundleID: "test.host")
        }
    }
}

@Test
func daemonShutdownTransientValidationIsRetryableAndNeverFiresPrematurely() async throws {
    let recorder = ShutdownRecorder()
    let flaky = FlakyValidator()
    let server = shutdownXPCServer(recorder: recorder, validator: flaky.validator)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    // First attempt: ephemeral `.unavailable` verdict → the RETRYABLE
    // `notReadyCode` (not a hard `roleViolationCode`), and it is NOT cached, so a
    // later attempt re-resolves. The GUI client's `request()` retries this code,
    // so a momentary signature-read blip doesn't abandon the shutdown.
    sendRequest(envelopeId: 1, method: RPCMethod.daemonShutdown.rawValue, client: clientPair)
    let first = try decodeEnvelope(reply: try await replyBox.awaitReply())
    guard case let .error(err) = first.body else {
        Issue.record("expected transient refusal, got \(first.body)")
        return
    }
    #expect(err.code == RPCMethodError.notReadyCode)
    #expect(err.code != RPCMethodError.roleViolationCode)
    #expect(await recorder.fired == 0)  // never fired on the refused attempt

    // Second attempt: the validator is now stable-production → authorized.
    sendRequest(envelopeId: 2, method: RPCMethod.daemonShutdown.rawValue, client: clientPair)
    let second = try decodeEnvelope(reply: try await replyBox.awaitReply())
    var acked = false
    if case .result = second.body { acked = true }
    #expect(acked)
    let fired = try await poll(timeout: 2.0) { await recorder.fired == 1 }
    #expect(fired)
}

// MARK: - 2 & 3. Refused over UDS for every role (unauth / agent / orchestrator)

@Test(arguments: [nil, SessionRole.agent, SessionRole.orchestrator] as [SessionRole?])
func daemonShutdownRefusedOverUDS(role: SessionRole?) async throws {
    let manager = SessionManager()
    var created: CreatedSession?
    if let role {
        created = try await manager.createSession(label: nil, role: role)
    }
    let path = tempSocketPath(prefix: "deviceterm-shut-uds")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }

    let client: TestClient
    if let created {
        client = try TestClient.connectAuthenticated(to: path, as: created)
    } else {
        client = try TestClient.connect(to: path)
    }
    defer { client.close() }

    // The scope gate runs before the handler, so the (ignored) body is empty.
    try client.send(
        RPCEnvelope(id: 1, type: .request, method: RPCMethod.daemonShutdown.rawValue, body: .empty)
    )
    let response = try client.receive()
    guard case let .error(error) = response.body else {
        Issue.record("expected daemon.shutdown refused over UDS; got \(response.body)")
        return
    }
    #expect(error.code == RPCMethodError.roleViolationCode)
}

// MARK: - 4. An orchestration grant does not authorize shutdown

@Test
func daemonShutdownRefusedForGrantedOrchestratorOverUDS() async throws {
    let grants = OrchestratorGrantStore()
    let manager = SessionManager(orchestratorGrantStore: grants)
    let created = try await manager.createSession(label: nil, role: .orchestrator)
    await grants.grant(
        sessionIds: [created.state.id],
        key: GrantOrderingKey(epoch: 1, revision: 1),
        issuedBy: 1
    )
    #expect(await grants.hasGrant(created.state.id))  // the grant is live

    let path = tempSocketPath(prefix: "deviceterm-shut-grant")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }
    let client = try TestClient.connectAuthenticated(to: path, as: created)
    defer { client.close() }

    try client.send(
        RPCEnvelope(id: 1, type: .request, method: RPCMethod.daemonShutdown.rawValue, body: .empty)
    )
    let response = try client.receive()
    guard case let .error(error) = response.body else {
        Issue.record("a grant must not authorize daemon.shutdown over UDS; got \(response.body)")
        return
    }
    // `.validatedGUI` is refused over UDS by construction. Grants are never
    // consulted for it.
    #expect(error.code == RPCMethodError.roleViolationCode)
}

// MARK: - 7. Capabilities advertises shutdown only where dispatch allows it

@Test
func daemonShutdownAdvertisedToValidatedGUIXPCPeer() async throws {
    let recorder = ShutdownRecorder()
    let server = shutdownXPCServer(recorder: recorder, validator: validatedGUIPeer)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    // No authenticated session: `.validatedGUI` reachability is the audit token,
    // matching dispatch, so daemon.shutdown is advertised to the validated peer.
    sendRequest(
        envelopeId: 1,
        method: RPCMethod.daemonCapabilities.rawValue,
        params: Data("{}".utf8),
        client: clientPair
    )
    let reply = try decodeEnvelope(reply: try await replyBox.awaitReply())
    guard case let .result(bytes) = reply.body else {
        Issue.record("expected capabilities result, got \(reply.body)")
        return
    }
    let advertised = try JSONDecoder().decode(DaemonCapabilitiesResponse.self, from: bytes)
    #expect(advertised.allowedMethods.contains(RPCMethod.daemonShutdown.rawValue))
}

@Test(arguments: [nil, SessionRole.agent, SessionRole.orchestrator] as [SessionRole?])
func daemonShutdownOmittedFromCapabilitiesOverUDS(role: SessionRole?) async throws {
    let manager = SessionManager()
    var created: CreatedSession?
    if let role {
        created = try await manager.createSession(label: nil, role: role)
    }
    let path = tempSocketPath(prefix: "deviceterm-shut-cap")
    let server = try await startServer(path: path, sessionManager: manager)
    defer { Task { await server.stop() } }

    let client: TestClient
    if let created {
        client = try TestClient.connectAuthenticated(to: path, as: created)
    } else {
        client = try TestClient.connect(to: path)
    }
    defer { client.close() }

    try client.send(
        RPCEnvelope(
            id: 1,
            type: .request,
            method: RPCMethod.daemonCapabilities.rawValue,
            body: .params(Data("{}".utf8))
        )
    )
    let response = try client.receive()
    guard case let .result(bytes) = response.body else {
        Issue.record("expected capabilities result, got \(response.body)")
        return
    }
    let advertised = try JSONDecoder().decode(DaemonCapabilitiesResponse.self, from: bytes)
    #expect(!advertised.allowedMethods.contains(RPCMethod.daemonShutdown.rawValue))
}
