// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import DaemonTestSupport
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

// Provenance enforcement through the real UDS dispatcher. The provenance
// MATRIX itself is unit-tested in `ProvenanceMatcherTests`; these tests pin
// that payload credentials cannot cross sessions and cannot substitute for
// kernel provenance.

private func panesListParams(_ session: String, _ cap: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["sessionId": session, "cap": cap])
}

// MARK: - Payload creds can't target a foreign session

@Test
func payloadCredentialsCannotTargetForeignSession() async throws {
    let manager = SessionManager()
    let path = tempSocketPath(prefix: "deviceterm-prov")
    // Authenticated as the harness (attacker) session A.
    let harness = try await startAuthenticatedHarness(path: path, sessionManager: manager)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    // A separate victim session B, whose valid cap the attacker has "stolen"
    // (readable via `ps -E` in the real threat model).
    let victim = try await manager.createSession(label: "victim")

    // The attacker's own connection (authenticated as A) pastes B's creds.
    try client.send(
        RPCEnvelope(
            id: 1,
            type: .request,
            method: RPCMethod.panesList.rawValue,
            body: .params(try panesListParams(victim.state.id.uuidString, victim.capability.token))
        )
    )
    let response = try client.receive()
    guard case let .error(err) = response.body else {
        Issue.record("expected rejection, got \(response.body)")
        return
    }
    #expect(err.code == RPCMethodError.unauthorizedCode)

    // Control: the same connection listing its OWN session succeeds.
    try client.send(
        RPCEnvelope(
            id: 2,
            type: .request,
            method: RPCMethod.panesList.rawValue,
            body: .params(
                try panesListParams(harness.state.id.uuidString, harness.capability.token)
            )
        )
    )
    guard case .result = try client.receive().body else {
        Issue.record("own-session panes.list should succeed")
        return
    }
}

// MARK: - Revocation bites an already-authenticated socket

@Test
func closedSessionRefusesAlreadyAuthenticatedSocket() async throws {
    let manager = SessionManager()
    let path = tempSocketPath(prefix: "deviceterm-prov")
    let harness = try await startAuthenticatedHarness(path: path, sessionManager: manager)
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    // Close the session out from under the still-open, still-authenticated
    // socket. The per-request provenance re-check must now refuse it.
    try await manager.closeSession(sessionId: harness.state.id, capability: harness.capability)

    try client.send(
        RPCEnvelope(
            id: 1,
            type: .request,
            method: RPCMethod.panesList.rawValue,
            body: .params(
                try panesListParams(harness.state.id.uuidString, harness.capability.token)
            )
        )
    )
    guard case let .error(err) = try client.receive().body else {
        Issue.record("closed-session request should be refused")
        return
    }
    #expect(err.code == RPCMethodError.unauthorizedCode)
}

@Test
func closedSessionDowngradesDaemonWideCapabilities() async throws {
    let manager = SessionManager()
    let path = tempSocketPath(prefix: "deviceterm-prov")
    let harness = try await startAuthenticatedHarness(
        path: path,
        sessionManager: manager,
        role: .automation
    )
    let server = harness.server
    let client = harness.client
    defer { client.close(); Task { await server.stop() } }

    // Before close: daemon.capabilities reflects the authenticated principal.
    try client.send(
        RPCEnvelope(
            id: 1,
            type: .request,
            method: RPCMethod.daemonCapabilities.rawValue,
            body: .empty
        )
    )
    let before = try decodeCapabilities(try client.receive())
    #expect(before.role == .automation)

    // After close: the daemon-wide handler must NOT keep advertising the stale
    // (now-closed) principal; the effective session downgrades to nil.
    try await manager.closeSession(sessionId: harness.state.id, capability: harness.capability)
    try client.send(
        RPCEnvelope(
            id: 2,
            type: .request,
            method: RPCMethod.daemonCapabilities.rawValue,
            body: .empty
        )
    )
    let after = try decodeCapabilities(try client.receive())
    #expect(after.role == nil)
}

private func decodeCapabilities(_ envelope: RPCEnvelope) throws -> DaemonCapabilitiesResponse {
    guard case let .result(bytes) = envelope.body else {
        throw ProvenanceTestError.notResult
    }
    return try JSONDecoder().decode(DaemonCapabilitiesResponse.self, from: bytes)
}

private enum ProvenanceTestError: Error { case notResult }

// MARK: - The anchor store is shared between manager and registry

@Test
func sessionManagerRegistersIntoItsOwnAnchorStore() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)

    // The manager's store, the SAME instance `defaultRegistry` derives for the
    // bindTerminal handler, must have the session registered live. A bind into
    // a disconnected store would report `.sessionNotLive`.
    let facts = TerminalAnchorFacts(
        terminalSessionId: 7, sessionLeaderStartTime: 3, controllingTTYDevice: 9
    )
    let applied = await manager.terminalAnchorStore.bind(
        sessionId: created.state.id, facts: facts, issuedBy: 1
    )
    #expect(applied == .applied)

    // Control: an unregistered session is rejected, proving the liveness gate
    // is real (not a store that accepts anything).
    let unknown = await manager.terminalAnchorStore.bind(
        sessionId: UUID(), facts: facts, issuedBy: 1
    )
    #expect(unknown == .sessionNotLive)
}

// MARK: - initial binding: bindTerminal handler → terminal provenance arm

@Test
func bindTerminalHandlerAnchorsSessionForMatchingTerminalPeer() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)  // registers live in the store

    // The validated GUI binds the terminal via the handler. Inject a stub probe
    // so no real syscalls run; it stands in for the kernel-derived facts.
    let facts = TerminalAnchorFacts(
        terminalSessionId: 55, sessionLeaderStartTime: 7, controllingTTYDevice: 3
    )
    let handler = SessionMethods.bindTerminal(
        store: manager.terminalAnchorStore,
        probe: { _, _ in facts }
    )
    let context = DispatchPeerContext(transport: .xpc, connectionId: 1, validatedGUIPeer: true)
    let ackBytes = try await DispatchPeerContext.$current.withValue(context) {
        try await handler(
            try paramsBytes(
                SessionBindTerminalParams(
                    sessionId: created.state.id.uuidString,
                    foregroundPid: 999,
                    ttyName: "/dev/ttys999"
                )
            )
        )
    }
    #expect(try JSONDecoder().decode(RPCAck.self, from: ackBytes).success)

    // The anchor is now stored; a UDS peer whose kernel facts match authorizes
    // via the terminal arm (no owner needed), the whole point of binding.
    let anchor = try #require(await manager.terminalAnchorStore.anchor(for: created.state.id))
    let peer = PeerProcessIdentity(
        pid: 300,
        pidVersion: 1,
        euid: geteuid(),
        posixSessionId: 55,
        controllingTTYDev: 3,
        posixSessionLeaderStartTime: 7
    )
    #expect(
        ProvenanceMatcher.verdict(peer: .uds(peer, ancestors: []), sessionOwner: nil, anchor: anchor.facts)
            == .authorized
    )
    // A DIFFERENT terminal (wrong tty) is rejected even with the anchor present.
    let stranger = PeerProcessIdentity(
        pid: 301,
        pidVersion: 1,
        euid: geteuid(),
        posixSessionId: 55,
        controllingTTYDev: 9,
        posixSessionLeaderStartTime: 7
    )
    #expect(
        ProvenanceMatcher.verdict(peer: .uds(stranger, ancestors: []), sessionOwner: nil, anchor: anchor.facts)
            == .unauthorized
    )
}

// MARK: - Anchored ancestry, re-walked per request

@Test
func anchoredAncestryAuthorizesUntilTheChainIsSevered() async throws {
    // The invariant, through the real dispatcher: a detached caller can start
    // scoped requests while an ancestor remains in the bound terminal, and
    // subsequent scoped requests are refused after the chain is severed. Hop
    // zero here has its own POSIX session and no controlling tty, so nothing
    // but the ancestry arm can authorize any of this.
    let manager = SessionManager()
    let broker = EventBroker()
    let chain = TestPeerIdentity.AncestorChain([TestPeerIdentity.anchoredAncestor])
    let path = tempSocketPath(prefix: "deviceterm-ancestry")
    let server = RPCServer(
        socketPath: path,
        methods: DaemonMethods.defaultRegistry(
            sessionManager: manager,
            deviceCoordinator: DeviceCoordinator(),
            paneCoordinator: PaneCoordinator(),
            eventBroker: broker,
            provenance: TestPeerIdentity.udsProvenance(manager)
        ),
        authValidator: { try await manager.validate(sessionId: $0, capability: $1) },
        peerIdentityResolver: TestPeerIdentity.detachedResolver,
        // The chain is re-read on every scoped request, which is the only
        // reason severing it mid-connection is observable at all.
        provenanceSnapshotResolver: chain.resolver
    )
    try await server.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    defer { Task { await server.stop() } }

    let created = try await manager.createSession(label: nil)
    // `connectAuthenticated` throws if `session.authenticate` is refused, so
    // reaching the next line already proves the ancestry arm carried the
    // handshake for a peer that matches no anchor itself.
    let client = try TestClient.connectAuthenticated(to: path, as: created)
    defer { client.close() }

    // A scoped request over the intact chain.
    try client.send(
        RPCEnvelope(
            id: 1,
            type: .request,
            method: RPCMethod.panesList.rawValue,
            body: .params(try panesListParams(created.state.id.uuidString, created.capability.token))
        )
    )
    guard case .result = try client.receive().body else {
        Issue.record("an anchored ancestor should authorize a scoped request")
        return
    }

    // Open a stream while the chain is still intact.
    try client.send(
        RPCEnvelope(id: 2, type: .request, method: RPCMethod.daemonEvents.rawValue, body: .empty)
    )
    guard case .result = try client.receive().body else {
        Issue.record("daemon.events subscribe should be acked over the intact chain")
        return
    }

    // Orphan the caller: no live ancestor reaches the terminal any more.
    chain.set([])

    try client.send(
        RPCEnvelope(
            id: 3,
            type: .request,
            method: RPCMethod.panesList.rawValue,
            body: .params(try panesListParams(created.state.id.uuidString, created.capability.token))
        )
    )
    guard case let .error(err) = try client.receive().body else {
        Issue.record("a severed chain should refuse the next scoped request")
        return
    }
    // A severed chain is permanent for that process, so it lands on the hard
    // code rather than the retryable one an unbound anchor would give.
    #expect(err.code == RPCMethodError.unauthorizedCode)

    // The already-open stream is untouched: losing the chain blocks new calls,
    // it does not revoke a subscription. Only a hard session close does that.
    let event = DaemonEvent.sessionCreated(
        sessionId: created.state.id.uuidString, shortId: "AA", name: nil
    )
    await broker.publish(event, to: .session(created.state.id))
    let streamed = try client.receive()
    #expect(streamed.type == .event)
    #expect(streamed.id == 2)

    // Restoring the chain restores authority, which pins the refusal to the
    // chain rather than to some latched connection state.
    chain.set([TestPeerIdentity.anchoredAncestor])
    try client.send(
        RPCEnvelope(
            id: 4,
            type: .request,
            method: RPCMethod.panesList.rawValue,
            body: .params(try panesListParams(created.state.id.uuidString, created.capability.token))
        )
    )
    guard case .result = try client.receive().body else {
        Issue.record("a restored chain should authorize again")
        return
    }
}

// MARK: - Missing provenance wiring fails closed

@Test
func provenanceFailsClosedWhenLookupAbsent() async throws {
    // A server configured with a validator but NO provenance lookup must NOT
    // silently admit; provenance is the security boundary, so it fails closed.
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)
    let path = tempSocketPath(prefix: "deviceterm-prov")
    let server = RPCServer(
        socketPath: path,
        methods: DaemonMethods.defaultRegistry(
            sessionManager: manager,
            deviceCoordinator: DeviceCoordinator(),
            paneCoordinator: PaneCoordinator()
        ),
        authValidator: { try await manager.validate(sessionId: $0, capability: $1) },
        // No sessionProvenanceLookup: the misconfiguration under test.
        peerIdentityResolver: TestPeerIdentity.udsResolver
    )
    try await server.start()
    try await Task.sleep(nanoseconds: 50_000_000)
    defer { Task { await server.stop() } }

    let client = try TestClient.connect(to: path)
    defer { client.close() }
    try client.send(
        RPCEnvelope(
            id: 0,
            type: .request,
            method: RPCMethod.sessionAuthenticate.rawValue,
            body: .params(
                try paramsBytes(
                    SessionAuthenticateParams(
                        sessionId: created.state.id.uuidString,
                        cap: created.capability.token
                    )
                )
            )
        )
    )
    guard case let .error(err) = try client.receive().body else {
        Issue.record("authenticate must fail closed without a provenance lookup")
        return
    }
    #expect(err.code == RPCMethodError.unauthorizedCode)
}
