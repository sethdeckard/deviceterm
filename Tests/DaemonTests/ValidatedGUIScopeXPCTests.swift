// SPDX-License-Identifier: GPL-3.0-or-later

@_spi(ProvenanceTesting)
@testable import Daemon
import DaemonProtocol
import DaemonTestSupport
import Foundation
import Testing
@preconcurrency import XPC

// The `.validatedGUI` scope, exercised over the real XPC dispatch path
// with an injected `PeerValidator`: the two properties that make the
// GUI back-channel reachable by the GUI and no one else:
//
//   A) It does NOT require an authenticated session (unlike `.session`).
//      The GUI subscribes to `app.commands` at startup before it has
//      created any tab, so a validated peer must reach it with no
//      session on the connection.
//   B) An XPC peer that fails signature validation is refused: the
//      audit token, not mere use of the XPC transport, is the anchor.

private func backChannelServer(
    coordinator: AppCommandCoordinator,
    validator: @escaping PeerValidator
) -> XPCServer {
    let manager = SessionManager()
    let registry = MethodRegistry(
        handlers: [
            RPCMethod.appCommandResult.rawValue:
                .validatedGUI(AppCommandMethods.commandResult(coordinator: coordinator))
        ],
        subscriptions: [
            RPCMethod.appCommands.rawValue:
                .validatedGUI(AppCommandMethods.commandsSubscription(coordinator: coordinator))
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

private let rejectedPeer: PeerValidator = { _ in .rejected(reason: "test") }

private let unavailablePeer: PeerValidator = { _ in .unavailable(reason: "test") }

// A transient XPC validation failure (`.unavailable`, not cached) on an
// anchor-less session (no owner identity, so the exact-owner arm can't cover)
// must return the RETRYABLE `-32002`, NOT a hard `-32001`. A `-32001` would let
// the GUI client prune a live credential as a "deleted session"; `-32002` makes
// it retry, and validation usually succeeds on the next attempt.
@Test
func transientValidationYieldsRetryableNotReadyNotUnauthorized() async throws {
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)
    let registry = DaemonMethods.defaultRegistry(
        sessionManager: manager,
        deviceCoordinator: DeviceCoordinator(),
        paneCoordinator: PaneCoordinator(),
        provenance: ProvenanceContext(
            sessionManager: manager,
            // Rehydrated: the session carries NO owner identity.
            lookupOverride: { sessionId in
                guard await manager.session(id: sessionId) != nil else { return nil }
                return SessionProvenanceSnapshot(owner: nil, anchor: nil)
            }
        )
    )
    let server = XPCServer(
        methods: registry,
        authValidator: { try await manager.validate(sessionId: $0, capability: $1) },
        peerValidator: unavailablePeer
    )
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    let params = try JSONEncoder().encode(
        SessionAuthenticateParams(
            sessionId: created.state.id.uuidString,
            cap: created.capability.token
        )
    )
    sendRequest(envelopeId: 1, method: RPCMethod.sessionAuthenticate.rawValue, params: params, client: clientPair)
    let envelope = try decodeEnvelope(reply: try await replyBox.awaitReply())
    guard case let .error(error) = envelope.body else {
        Issue.record("transient validation on an anchor-less session must fail, retryably")
        return
    }
    #expect(error.code == RPCMethodError.notReadyCode)
    #expect(error.code != RPCMethodError.unauthorizedCode)
}

/// A validator whose verdict changes across calls: `.unavailable` (ephemeral)
/// on the first walk, `.production` (stable) after. Proves an ephemeral verdict
/// is resolved fresh per request and never "upgraded" by a later stable one.
///
/// `@unchecked Sendable` invariant: the validator runs on the verdict cache's
/// detached task and can be invoked concurrently, so every access to the only
/// mutable field (`calls`) is serialized under `lock`.
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
func ephemeralVerdictYieldsNotReadyEvenThoughALaterVerdictWouldBeStable() async throws {
    // The immutable-snapshot property: the first authenticate resolves an
    // ephemeral verdict and MUST return the retryable `-32002` on its own
    // snapshot. The fact that a subsequent resolve would be stable-production
    // (and authorize) can't retroactively harden it into `-32001`. An anchor-less
    // session (no owner) means only the validated-GUI arm could authorize.
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)
    let flaky = FlakyValidator()
    let registry = DaemonMethods.defaultRegistry(
        sessionManager: manager,
        deviceCoordinator: DeviceCoordinator(),
        paneCoordinator: PaneCoordinator(),
        provenance: ProvenanceContext(
            sessionManager: manager,
            lookupOverride: { sessionId in
                guard await manager.session(id: sessionId) != nil else { return nil }
                return SessionProvenanceSnapshot(owner: nil, anchor: nil)  // anchor-less (terminal not yet bound)
            }
        )
    )
    let server = XPCServer(
        methods: registry,
        authValidator: { try await manager.validate(sessionId: $0, capability: $1) },
        peerValidator: flaky.validator
    )
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    let params = try JSONEncoder().encode(
        SessionAuthenticateParams(
            sessionId: created.state.id.uuidString,
            cap: created.capability.token
        )
    )
    // First authenticate: ephemeral verdict → retryable `-32002`, never `-32001`.
    sendRequest(envelopeId: 1, method: RPCMethod.sessionAuthenticate.rawValue, params: params, client: clientPair)
    let first = try decodeEnvelope(reply: try await replyBox.awaitReply())
    guard case let .error(err1) = first.body else {
        Issue.record("ephemeral first authenticate must fail retryably")
        return
    }
    #expect(err1.code == RPCMethodError.notReadyCode)

    // Second authenticate: the validator is now stable-production → the
    // validated-GUI arm authorizes. Proves the verdict was re-resolved fresh.
    sendRequest(envelopeId: 2, method: RPCMethod.sessionAuthenticate.rawValue, params: params, client: clientPair)
    let second = try decodeEnvelope(reply: try await replyBox.awaitReply())
    var secondAuthorized = false
    if case .result = second.body { secondAuthorized = true }
    #expect(secondAuthorized)
}

/// Blocks the FIRST provenance-lookup call on a semaphore (later calls pass
/// through), so a test can park request A inside its lookup (AFTER A has
/// resolved its verdict snapshot) while request B runs to completion.
///
/// `@unchecked Sendable` invariant: the lookup closure runs off-actor and both
/// requests can enter concurrently, so the mutable bookkeeping (`firstEntered`,
/// `didEnter`) is serialized under `lock`; cross-request handoff rides the
/// `release` semaphore, which is itself thread-safe.
private final class LookupGate: @unchecked Sendable {
    private let lock = NSLock()
    private var firstEntered = false
    private var didEnter = false
    let release = DispatchSemaphore(value: 0)

    /// True once some call has entered `blockFirst`. Lets the test wait for
    /// positive evidence that A is parked before it sends B.
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return didEnter }

    /// Block only the first caller until `release` is signaled; every later
    /// caller returns immediately.
    func blockFirst() {
        lock.lock()
        if firstEntered { lock.unlock(); return }
        firstEntered = true
        didEnter = true
        lock.unlock()
        _ = release.wait(timeout: .now() + 5)
    }
}

@Test
func inFlightEphemeralAuthenticateStaysNotReadyWhenAConcurrentAuthenticateCachesStable() async throws {
    // The staged race the immutable snapshot defends against. Request A resolves
    // an ephemeral verdict, then PARKS inside its provenance lookup, past the
    // point where its `(validatedGUI, verdictStable)` snapshot is fixed. While A
    // is parked, request B (same connection) resolves a stable-production verdict,
    // caches it, and stamps the connection's `guiPeerVerdict = true`. A then
    // resumes.
    //
    // The failure this guards against: if A's decision re-read the now-mutated
    // connection verdict instead of its own snapshot, B's stable-true would make
    // A's `!validatedGUI, !verdictStable` retryable branch fall through to the
    // HARD `-32001`, pruning a valid credential the GUI should have been told to
    // retry (a live GUI would drop the session as deleted). A carries its IMMUTABLE
    // `(false, false)` snapshot, so it must still return the retryable `-32002`.
    // (The `.error`-not-`.result` guard below also catches the sharper variant
    // where re-reading the verdict flips A all the way to authorized; the primary
    // regression is the `-32002` → `-32001` downgrade.) An anchor-less session (no
    // owner) leaves the validated-GUI arm as the only path to authorize, so the
    // field read vs. snapshot read is the whole difference.
    let manager = SessionManager()
    let created = try await manager.createSession(label: nil)
    let flaky = FlakyValidator()
    let gate = LookupGate()
    let registry = DaemonMethods.defaultRegistry(
        sessionManager: manager,
        deviceCoordinator: DeviceCoordinator(),
        paneCoordinator: PaneCoordinator(),
        provenance: ProvenanceContext(
            sessionManager: manager,
            lookupOverride: { sessionId in
                guard await manager.session(id: sessionId) != nil else { return nil }
                gate.blockFirst()  // A parks here; B's (2nd) lookup passes through
                return SessionProvenanceSnapshot(owner: nil, anchor: nil)  // anchor-less (terminal not yet bound)
            }
        )
    )
    let server = XPCServer(
        methods: registry,
        authValidator: { try await manager.validate(sessionId: $0, capability: $1) },
        peerValidator: flaky.validator
    )
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    let params = try JSONEncoder().encode(
        SessionAuthenticateParams(
            sessionId: created.state.id.uuidString,
            cap: created.capability.token
        )
    )

    // Send A. It resolves the ephemeral verdict (validator call #1) and parks in
    // the lookup gate, no reply yet. Wait for positive evidence it's parked.
    sendRequest(envelopeId: 1, method: RPCMethod.sessionAuthenticate.rawValue, params: params, client: clientPair)
    let parked = try await poll(timeout: 2.0) { gate.entered }
    #expect(parked)

    // Send B while A is parked. B resolves a stable-production verdict (validator
    // call #2), caches it, and stamps `guiPeerVerdict = true` on the shared
    // connection. Its lookup is the 2nd call, so it passes the gate and B
    // authorizes. Only B can reply while A is parked, so this reply is B's.
    sendRequest(envelopeId: 2, method: RPCMethod.sessionAuthenticate.rawValue, params: params, client: clientPair)
    let bReply = try decodeEnvelope(reply: try await replyBox.awaitReply())
    #expect(bReply.id == 2)
    var bAuthorized = false
    if case .result = bReply.body { bAuthorized = true }
    #expect(bAuthorized)

    // Now release A. The connection's `guiPeerVerdict` is `true` (B set it), but A
    // must decide on its OWN `(false, false)` snapshot → still the retryable
    // `-32002`, never the hard `-32001` that would prune a valid credential.
    gate.release.signal()
    let aReply = try decodeEnvelope(reply: try await replyBox.awaitReply())
    #expect(aReply.id == 1)
    guard case let .error(aError) = aReply.body else {
        Issue.record("A must stay retryable; re-reading B's cached verdict wrongly authorized it")
        return
    }
    // The primary regression: a hard `-32001` here means A re-read the mutated
    // verdict and downgraded its own retryable snapshot, pruning the credential.
    #expect(aError.code == RPCMethodError.notReadyCode)
    #expect(aError.code != RPCMethodError.unauthorizedCode)
}

@Test
func validatedGUIScopeDoesNotRequireAuthentication() async throws {
    let coord = AppCommandCoordinator()
    let server = backChannelServer(coordinator: coord, validator: validatedGUI)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    // Subscribe to app.commands WITHOUT authenticating a session first.
    // A `.session` scope would reject this at the gate; `.validatedGUI`
    // admits the validated peer on its audit token alone.
    sendRequest(envelopeId: 1, method: RPCMethod.appCommands.rawValue, client: clientPair)
    let envelope = try decodeEnvelope(reply: try await replyBox.awaitReply())
    if case let .error(error) = envelope.body {
        Issue.record("a validated GUI must reach app.commands without a session; got error \(error.code)")
        return
    }
    #expect(await coord.hasSubscriber)
}

@Test
func unvalidatedXPCPeerRefusedFromBackChannel() async throws {
    let coord = AppCommandCoordinator()
    let server = backChannelServer(coordinator: coord, validator: rejectedPeer)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    sendRequest(envelopeId: 1, method: RPCMethod.appCommands.rawValue, client: clientPair)
    let envelope = try decodeEnvelope(reply: try await replyBox.awaitReply())
    guard case let .error(error) = envelope.body else {
        Issue.record("an unvalidated XPC peer must be refused the back-channel; got \(envelope.body)")
        return
    }
    #expect(error.code == RPCMethodError.roleViolationCode)
    #expect(await coord.hasSubscriber == false)
}
