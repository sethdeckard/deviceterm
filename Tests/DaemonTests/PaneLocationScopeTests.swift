// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import DaemonTestSupport
import Foundation
import Testing
@preconcurrency import XPC

// The scope gate on `pane.location.*`: the tests that pin deviceterm's
// philosophy gate in CI.
//
// `docs/PHILOSOPHY.md` principle #3 rejects reimplementing what `xcrun
// simctl` already does; the CLI's own "no simctl wrappers" reject list
// applies that principle by naming `location` explicitly, and
// `deviceterm agents` prints it verbatim to every agent that asks (see
// `Sources/DeviceTermCLI/AgentsText.swift`). Location is therefore a GUI
// affordance with no CLI verb. Tagging both methods
// `.validatedGUI` turns that from a convention anyone could quietly
// break into a dispatch fact: UDS carries no audit token, so
// `MethodScope.validatedGUIReachable` refuses it unconditionally and no
// CLI, script, or in-tab agent can reach location even by hand-rolling a
// frame.
//
// These tests fail if either method is tagged `.session`.

private let validatedGUIPeer: PeerValidator = { _ in
    .production(peerTeamID: "TEST", peerBundleID: "test.host")
}
private let rejectedGUIPeer: PeerValidator = { _ in .rejected(reason: "test") }

/// Round-trip one envelope over a real UDS server built from
/// `DaemonMethods.defaultRegistry`, optionally authenticating first.
///
/// Goes through the production registry rather than a hand-built one on
/// purpose: these tests assert the production registry's scope tagging,
/// so a registry assembled here would defeat them.
private func locationRoundTrip(
    _ envelope: RPCEnvelope,
    manager: SessionManager,
    authenticatedAs created: CreatedSession
) async throws -> RPCEnvelope {
    let path = tempSocketPath(prefix: "deviceterm-loc")
    let server = RPCServer(
        socketPath: path,
        methods: DaemonMethods.defaultRegistry(
            sessionManager: manager,
            deviceCoordinator: DeviceCoordinator(),
            paneCoordinator: PaneCoordinator(),
            provenance: TestPeerIdentity.udsProvenance(manager)
        ),
        authValidator: { try await manager.validate(sessionId: $0, capability: $1) },
        peerIdentityResolver: TestPeerIdentity.udsResolver
    )
    try await server.start()
    defer { Task { await server.stop() } }
    try await Task.sleep(nanoseconds: 50_000_000)

    let fd = try UDSSocket.connectClient(to: path)
    defer { Darwin.close(fd) }

    let authParams = SessionAuthenticateParams(
        sessionId: created.state.id.uuidString,
        cap: created.capability.token
    )
    let authEnvelope = RPCEnvelope(
        id: 0,
        type: .request,
        method: RPCMethod.sessionAuthenticate.rawValue,
        body: .params(try JSONEncoder().encode(authParams))
    )
    try UDSSocket.writeAll(fd: fd, data: RPCFraming.encode(try authEnvelope.encode()))
    _ = try awaitLocationFrame(fd: fd)  // drain the auth ack

    try UDSSocket.writeAll(fd: fd, data: RPCFraming.encode(try envelope.encode()))
    return try awaitLocationFrame(fd: fd)
}

private func awaitLocationFrame(fd: Int32, timeoutSeconds: Double = 2) throws -> RPCEnvelope {
    let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
    var buffer = Data()
    while Date() < deadline {
        if let frame = try RPCFraming.decodeNext(from: buffer) {
            return try RPCEnvelope.decode(frame.payload)
        }
        if let chunk = try UDSSocket.readAvailable(fd: fd), !chunk.isEmpty {
            buffer.append(chunk)
            continue
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    throw LocationFrameTimeout()
}

private struct LocationFrameTimeout: Error {}

private func locationServer(
    manager: SessionManager,
    paneCoordinator: PaneCoordinator,
    validator: @escaping PeerValidator
) -> XPCServer {
    let registry = MethodRegistry(
        handlers: [
            RPCMethod.paneLocationState.rawValue:
                .validatedGUI(PaneMethods.locationState(paneCoordinator: paneCoordinator))
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

/// The validated GUI peer reaches the method on its audit token alone,
/// with no `session.authenticate` first, exactly like the other
/// `.validatedGUI` methods.
@Test
func locationStateOverValidatedXPCIsAdmitted() async throws {
    let manager = SessionManager()
    let paneCoordinator = PaneCoordinator()
    let server = locationServer(
        manager: manager,
        paneCoordinator: paneCoordinator,
        validator: validatedGUIPeer
    )
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    let body = try JSONEncoder().encode(
        PaneLocationStateParams(paneId: UUID().uuidString)
    )
    sendRequest(
        envelopeId: 1,
        method: RPCMethod.paneLocationState.rawValue,
        params: body,
        client: clientPair
    )
    let envelope = try decodeEnvelope(reply: try await replyBox.awaitReply())
    // The pane doesn't exist, so the handler answers `notFound`
    // (`invalidParams`). That is the *handler* speaking, meaning the
    // scope gate let the call through. A scope refusal would be
    // `roleViolation` instead.
    guard case let .error(error) = envelope.body else { return }
    #expect(error.code != RPCMethodError.roleViolationCode)
}

@Test
func locationStateOverUnvalidatedXPCIsRefused() async throws {
    let manager = SessionManager()
    let paneCoordinator = PaneCoordinator()
    let server = locationServer(
        manager: manager,
        paneCoordinator: paneCoordinator,
        validator: rejectedGUIPeer
    )
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    let body = try JSONEncoder().encode(
        PaneLocationStateParams(paneId: UUID().uuidString)
    )
    sendRequest(
        envelopeId: 1,
        method: RPCMethod.paneLocationState.rawValue,
        params: body,
        client: clientPair
    )
    let envelope = try decodeEnvelope(reply: try await replyBox.awaitReply())
    guard case let .error(error) = envelope.body else {
        Issue.record("expected an error body for an unvalidated peer")
        return
    }
    #expect(error.code == RPCMethodError.roleViolationCode)
}

/// The load-bearing one. A fully authenticated UDS session, a real
/// in-tab agent holding a valid cap, still cannot reach location.
@Test(arguments: [RPCMethod.paneLocationSet, RPCMethod.paneLocationState])
func locationMethodsAreRefusedOverUDS(method: RPCMethod) async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil, name: nil)
    let paneId = UUID().uuidString
    let body: Data
    switch method {
    case .paneLocationSet:
        body = try JSONEncoder().encode(
            PaneLocationSetParams(paneId: paneId, location: .scenario(name: "City Run"))
        )

    default:
        body = try JSONEncoder().encode(PaneLocationStateParams(paneId: paneId))
    }
    let envelope = RPCEnvelope(
        id: 1,
        type: .request,
        method: method.rawValue,
        body: .params(body)
    )
    let response = try await locationRoundTrip(
        envelope,
        manager: manager,
        authenticatedAs: created
    )
    guard case let .error(error) = response.body else {
        Issue.record("expected .error body for UDS \(method.rawValue); got \(response.body)")
        return
    }
    #expect(error.code == RPCMethodError.roleViolationCode)
}

/// `daemon.capabilities` must not advertise what it won't dispatch. A
/// UDS caller listing its `allowedMethods` never sees the location
/// surface, so the "no simctl wrappers" promise holds at the discovery
/// surface too, not just at dispatch.
@Test
func locationMethodsAreNotAdvertisedToUDSCallers() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil, role: .agent)
    let envelope = RPCEnvelope(
        id: 1,
        type: .request,
        method: RPCMethod.daemonCapabilities.rawValue,
        body: .params(Data("{}".utf8))
    )
    let response = try await locationRoundTrip(
        envelope,
        manager: manager,
        authenticatedAs: created
    )
    guard case let .result(bytes) = response.body else {
        Issue.record("expected a result body from daemon.capabilities")
        return
    }
    let capabilities = try JSONDecoder().decode(DaemonCapabilitiesResponse.self, from: bytes)
    // Sanity: this caller really does see the session surface, so an
    // empty/blanket-refusing list can't make the assertions below pass
    // for the wrong reason.
    #expect(capabilities.allowedMethods.contains(RPCMethod.paneInputTap.rawValue))
    #expect(!capabilities.allowedMethods.contains(RPCMethod.paneLocationSet.rawValue))
    #expect(!capabilities.allowedMethods.contains(RPCMethod.paneLocationState.rawValue))
}
