// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing
@preconcurrency import XPC

// The `PeerValidator` seam + verdict caching. The injected validator
// stands in for the real signature walk (which can't accept an
// in-process test peer: the runner *is* `PeerIdentity.selfIdentity`).
// Pins that a stable (production) verdict is walked at most once per
// connection (its result is cached) and that the verdict drives the
// orchestrator mint gate. Cross-connection dedup by process identity,
// and the non-cacheable path, are covered directly in
// `PeerVerdictCacheTests`.

/// A `@Sendable` counter for how many times the injected validator ran.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}

private func createOnlyServer(
    manager: SessionManager,
    validator: @escaping PeerValidator
) -> XPCServer {
    let registry = MethodRegistry(handlers: [
        RPCMethod.sessionCreate.rawValue: .daemonWide(SessionMethods.create(using: manager))
    ])
    return XPCServer(methods: registry, peerValidator: validator)
}

@Test
func peerVerdictResolvedOncePerConnectionAndCached() async throws {
    // Every dispatch stamps the verdict, but it's cached: two creates
    // on one connection ⇒ a single signature walk.
    let counter = CallCounter()
    let validator: PeerValidator = { _ in
        counter.bump()
        return .production(peerTeamID: "TEST", peerBundleID: "test.host")
    }
    let server = createOnlyServer(manager: SessionManager(), validator: validator)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    for id: UInt32 in [1, 2] {
        sendRequest(
            envelopeId: id,
            method: RPCMethod.sessionCreate.rawValue,
            params: Data("{}".utf8),
            client: clientPair
        )
        _ = try await replyBox.awaitReply()
    }
    #expect(counter.value == 1)
}

@Test
func verdictDrivesOrchestratorMint() async throws {
    // A validated peer mints an orchestrator session; a rejected peer is
    // refused with roleViolation, proving the cached verdict actually
    // gates the mint.
    let mintParams = try JSONEncoder().encode(
        SessionMethods.CreateParams(label: nil, role: .orchestrator)
    )

    // Validated → mint succeeds.
    do {
        let server = createOnlyServer(manager: SessionManager()) { _ in
            .production(peerTeamID: "TEST", peerBundleID: "test.host")
        }
        let (listener, clientPair) = makeAnonymousPair()
        let replyBox = ReplyBox()
        await server.bind(listener: listener)
        defer { Task { await server.stop() } }
        setupClient(clientPair, replyBox: replyBox)
        sendRequest(
            envelopeId: 1,
            method: RPCMethod.sessionCreate.rawValue,
            params: mintParams,
            client: clientPair
        )
        let envelope = try decodeEnvelope(reply: try await replyBox.awaitReply())
        guard case .result = envelope.body else {
            Issue.record("validated peer should mint an orchestrator session; got \(envelope.body)")
            return
        }
    }

    // Rejected → mint refused.
    do {
        let server = createOnlyServer(manager: SessionManager()) { _ in .rejected(reason: "test") }
        let (listener, clientPair) = makeAnonymousPair()
        let replyBox = ReplyBox()
        await server.bind(listener: listener)
        defer { Task { await server.stop() } }
        setupClient(clientPair, replyBox: replyBox)
        sendRequest(
            envelopeId: 1,
            method: RPCMethod.sessionCreate.rawValue,
            params: mintParams,
            client: clientPair
        )
        let envelope = try decodeEnvelope(reply: try await replyBox.awaitReply())
        guard case let .error(error) = envelope.body else {
            Issue.record("rejected peer must not mint an orchestrator session; got \(envelope.body)")
            return
        }
        #expect(error.code == RPCMethodError.roleViolationCode)
    }
}

@Test
func aTransientValidationFailureIsRetryableForOrchestratorMint() async throws {
    // An `.unavailable` verdict (a recoverable validation blip, not a signature
    // mismatch) must refuse an orchestrator mint with the RETRYABLE notReady, not
    // a terminal roleViolation, so opening an orchestrator tab survives the
    // blip (DaemonClient retries notReady). A stable `.rejected` stays hard
    // (covered by `verdictDrivesOrchestratorMint`).
    let mintParams = try JSONEncoder().encode(
        SessionMethods.CreateParams(label: nil, role: .orchestrator)
    )
    let server = createOnlyServer(manager: SessionManager()) { _ in .unavailable(reason: "blip") }
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)
    sendRequest(
        envelopeId: 1,
        method: RPCMethod.sessionCreate.rawValue,
        params: mintParams,
        client: clientPair
    )
    let envelope = try decodeEnvelope(reply: try await replyBox.awaitReply())
    guard case let .error(error) = envelope.body else {
        Issue.record("unavailable verdict should refuse the mint; got \(envelope.body)")
        return
    }
    #expect(error.code == RPCMethodError.notReadyCode)
}

@Test
func anUnvalidatedXPCAgentCreateSplitsOnValidationStability() async throws {
    // An AGENT create over XPC applies the SAME stable-vs-unstable split as the
    // orchestrator mint: a transient `.unavailable` verdict is retryable
    // (notReady) so a legit GUI blip self-heals; a STABLE `.rejected` signature
    // mismatch is a hard refusal (roleViolation); a validated peer creates.
    let agentParams = try JSONEncoder().encode(SessionMethods.CreateParams(label: nil))

    func agentCreateResult(_ verdict: @escaping PeerValidator) async throws -> RPCEnvelope.Body {
        let server = createOnlyServer(manager: SessionManager(), validator: verdict)
        let (listener, clientPair) = makeAnonymousPair()
        let replyBox = ReplyBox()
        await server.bind(listener: listener)
        defer { Task { await server.stop() } }
        setupClient(clientPair, replyBox: replyBox)
        sendRequest(
            envelopeId: 1,
            method: RPCMethod.sessionCreate.rawValue,
            params: agentParams,
            client: clientPair
        )
        return try decodeEnvelope(reply: try await replyBox.awaitReply()).body
    }

    // Transient → retryable notReady.
    guard case let .error(transient) = try await agentCreateResult({ _ in .unavailable(reason: "blip") }) else {
        Issue.record("unavailable verdict should refuse the agent create")
        return
    }
    #expect(transient.code == RPCMethodError.notReadyCode)

    // Stable mismatch → hard roleViolation.
    guard case let .error(stable) = try await agentCreateResult({ _ in .rejected(reason: "test") }) else {
        Issue.record("rejected verdict should refuse the agent create")
        return
    }
    #expect(stable.code == RPCMethodError.roleViolationCode)

    // Validated → creates.
    guard case .result = try await agentCreateResult({ _ in
        .production(peerTeamID: "TEST", peerBundleID: "test.host")
    }) else {
        Issue.record("validated peer should create")
        return
    }
}
