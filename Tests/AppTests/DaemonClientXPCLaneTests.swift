// SPDX-License-Identifier: GPL-3.0-or-later
//
// DaemonClientXPCLaneTests: the GUI's control and pane traffic use distinct
// XPC peers, so a pane subscription whose stream handshake stops answering
// cannot hold an unrelated control round-trip behind it.

@testable import App
import DaemonProtocol
import Foundation
import Testing
@preconcurrency import XPC

@MainActor
struct DaemonClientXPCLaneTests {
    @Test
    func parkedPaneSubscriptionDoesNotDelayControlReply() async throws {
        let controlPeer = LaneReplyPeer()
        let panePeer = LaneReplyPeer(stalling: [.paneSubscribe])
        controlPeer.start()
        panePeer.start()
        defer {
            controlPeer.stop()
            panePeer.stop()
        }

        let client = DaemonClient()
        await client.xpcConnectionForTesting().connectWithTestPeer(controlPeer.clientPeer)
        await client.paneXPCConnectionForTesting().connectWithTestPeer(panePeer.clientPeer)

        // Seed the same live-session credential production obtains when a tab
        // opens. The control peer answers create/auth/capabilities; the pane
        // peer must perform its own auth before subscribing.
        _ = try await client.createSession(label: nil, name: nil, role: .agent)

        let subscription = Task {
            try await client.subscribePane(paneId: UUID().uuidString)
        }
        #expect(await poll { panePeer.receivedMethods.contains(.paneSubscribe) })

        // Positive evidence that the pane handshake is still parked, then an
        // ordinary ping completes on the other peer. A single-connection
        // client would have sent both methods to the same test peer.
        #expect(await client.paneXPCConnectionForTesting().pendingRequestCountForTesting == 1)
        let pong = try await client.ping()
        #expect(pong.version == DaemonProtocolInfo.wireVersion)
        #expect(controlPeer.receivedMethods.contains(.daemonPing))
        #expect(!controlPeer.receivedMethods.contains(.paneSubscribe))
        #expect(panePeer.receivedMethods.starts(with: [.sessionAuthenticate, .paneSubscribe]))

        subscription.cancel()
        _ = try? await subscription.value
        await client.disconnect()
    }

    @Test
    func closingPanePrincipalReauthenticatesWithSurvivingSession() async throws {
        let controlPeer = LaneReplyPeer()
        let panePeer = LaneReplyPeer()
        controlPeer.start()
        panePeer.start()
        defer {
            controlPeer.stop()
            panePeer.stop()
        }

        let client = DaemonClient()
        await client.xpcConnectionForTesting().connectWithTestPeer(controlPeer.clientPeer)
        await client.paneXPCConnectionForTesting().connectWithTestPeer(panePeer.clientPeer)

        let first = try await client.createSession(label: nil, name: nil, role: .agent)
        let second = try await client.createSession(label: nil, name: nil, role: .agent)
        let stream = try await client.subscribePane(paneId: UUID().uuidString)
        #expect(panePeer.authenticatedSessionIds == [second.sessionId])

        try await client.closeSession(
            sessionId: second.sessionId,
            capability: second.capability
        )
        #expect(await poll {
            panePeer.authenticatedSessionIds == [second.sessionId, first.sessionId]
        })

        withExtendedLifetime(stream) {}
        await client.disconnect()
    }

    @Test
    func uncertainCloseMovesPaneAuthenticationToSurvivingSession() async throws {
        let controlPeer = LaneReplyPeer(invalidating: [.sessionClose])
        let panePeer = LaneReplyPeer()
        controlPeer.start()
        panePeer.start()
        defer {
            controlPeer.stop()
            panePeer.stop()
        }

        let client = DaemonClient()
        await client.xpcConnectionForTesting().connectWithTestPeer(controlPeer.clientPeer)
        await client.paneXPCConnectionForTesting().connectWithTestPeer(panePeer.clientPeer)

        let first = try await client.createSession(label: nil, name: nil, role: .agent)
        let second = try await client.createSession(label: nil, name: nil, role: .agent)
        let stream = try await client.subscribePane(paneId: UUID().uuidString)

        await #expect(throws: DaemonClientError.self) {
            try await client.closeSession(
                sessionId: second.sessionId,
                capability: second.capability
            )
        }
        #expect(await poll {
            panePeer.authenticatedSessionIds == [second.sessionId, first.sessionId]
        })

        withExtendedLifetime(stream) {}
        await client.disconnect()
    }

    @Test
    func paneRepairDoesNotDelayConfirmedSessionClose() async throws {
        let controlPeer = LaneReplyPeer()
        let panePeer = LaneReplyPeer()
        controlPeer.start()
        panePeer.start()
        defer {
            controlPeer.stop()
            panePeer.stop()
        }

        let client = DaemonClient()
        await client.xpcConnectionForTesting().connectWithTestPeer(controlPeer.clientPeer)
        let paneConnection = client.paneXPCConnectionForTesting()
        await paneConnection.connectWithTestPeer(panePeer.clientPeer)

        _ = try await client.createSession(label: nil, name: nil, role: .agent)
        let closing = try await client.createSession(label: nil, name: nil, role: .agent)
        let stream = try await client.subscribePane(paneId: UUID().uuidString)
        panePeer.stall(.sessionAuthenticate)

        var closeFinished = false
        let close = Task { @MainActor in
            try await client.closeSession(
                sessionId: closing.sessionId,
                capability: closing.capability
            )
            closeFinished = true
        }

        #expect(await poll {
            let repairPending = await paneConnection.pendingRequestCountForTesting == 1
            return repairPending && closeFinished
        })

        await client.disconnect()
        _ = try? await close.value
        withExtendedLifetime(stream) {}
    }

    @Test
    func rapidClosesCannotRestoreAClosedPanePrincipal() async throws {
        let controlPeer = LaneReplyPeer()
        let panePeer = LaneReplyPeer()
        controlPeer.start()
        panePeer.start()
        defer {
            controlPeer.stop()
            panePeer.stop()
        }

        let client = DaemonClient()
        await client.xpcConnectionForTesting().connectWithTestPeer(controlPeer.clientPeer)
        let paneConnection = client.paneXPCConnectionForTesting()
        await paneConnection.connectWithTestPeer(panePeer.clientPeer)

        let first = try await client.createSession(label: nil, name: nil, role: .agent)
        let second = try await client.createSession(label: nil, name: nil, role: .agent)
        let third = try await client.createSession(label: nil, name: nil, role: .agent)
        let stream = try await client.subscribePane(paneId: UUID().uuidString)
        #expect(panePeer.authenticatedSessionIds == [third.sessionId])

        panePeer.holdNext(.sessionAuthenticate)
        try await client.closeSession(sessionId: third.sessionId, capability: third.capability)
        #expect(await poll {
            let repairPending = await paneConnection.pendingRequestCountForTesting == 1
            return repairPending
                && panePeer.authenticatedSessionIds == [third.sessionId, second.sessionId]
        })

        try await client.closeSession(sessionId: second.sessionId, capability: second.capability)
        panePeer.releaseHeld(.sessionAuthenticate)

        #expect(await poll {
            let repairComplete = await paneConnection.pendingRequestCountForTesting == 0
            return repairComplete && panePeer.authenticatedSessionIds == [
                third.sessionId,
                second.sessionId,
                first.sessionId
            ]
        })

        withExtendedLifetime(stream) {}
        await client.disconnect()
    }

    @Test
    func unknownPaneAuthenticationResultForcesPrincipalRepair() async throws {
        let controlPeer = LaneReplyPeer()
        let panePeer = LaneReplyPeer()
        let recoveryPeer = LaneReplyPeer()
        controlPeer.start()
        panePeer.start()
        recoveryPeer.start()
        defer {
            controlPeer.stop()
            panePeer.stop()
            recoveryPeer.stop()
        }

        let client = DaemonClient()
        await client.xpcConnectionForTesting().connectWithTestPeer(controlPeer.clientPeer)
        let paneConnection = client.paneXPCConnectionForTesting()
        await paneConnection.connectWithTestPeer(panePeer.clientPeer)

        let first = try await client.createSession(label: nil, name: nil, role: .agent)
        let firstStream = try await client.subscribePane(paneId: UUID().uuidString)
        let second = try await client.createSession(label: nil, name: nil, role: .agent)
        panePeer.holdNext(.sessionAuthenticate)
        client.requestDeadlineNanos = 50_000_000

        await #expect(throws: DaemonClientError.self) {
            _ = try await client.subscribePane(paneId: UUID().uuidString)
        }
        #expect(panePeer.authenticatedSessionIds == [first.sessionId, second.sessionId])
        #expect(await paneConnection.pendingRequestCountForTesting == 0)

        // Stand in for the next production demand-connect. Closing the
        // remotely accepted session must repair to the survivor; a stale local
        // cache of `first` would incorrectly suppress this rotation.
        await paneConnection.connectWithTestPeer(recoveryPeer.clientPeer)
        try await client.closeSession(sessionId: second.sessionId, capability: second.capability)
        #expect(await poll {
            recoveryPeer.authenticatedSessionIds == [first.sessionId]
        })

        withExtendedLifetime(firstStream) {}
        await client.disconnect()
    }

    @Test
    func terminalMismatchQuiescesPaneLane() async {
        let panePeer = LaneReplyPeer(stalling: [.daemonPing])
        panePeer.start()
        defer { panePeer.stop() }

        let client = DaemonClient()
        let paneConnection = client.paneXPCConnectionForTesting()
        await paneConnection.connectWithTestPeer(panePeer.clientPeer)
        let parked = Task {
            try await paneConnection.request(method: RPCMethod.daemonPing.rawValue, params: nil)
        }
        #expect(await poll { await paneConnection.pendingRequestCountForTesting == 1 })

        await client.surfaceVersionMismatch(
            .versionMismatch(client: DaemonProtocolInfo.wireVersion, daemon: "future"),
            generation: 999
        )

        do {
            _ = try await parked.value
            Issue.record("expected the pane request to be quiesced")
        } catch let DaemonClientError.transport(message) {
            #expect(message.contains("incompatible"))
        } catch {
            Issue.record("expected the pane-lane transport error, got \(error)")
        }
        #expect(await paneConnection.pendingRequestCountForTesting == 0)

        do {
            _ = try await paneConnection.request(method: RPCMethod.daemonPing.rawValue, params: nil)
            Issue.record("expected the terminal pane lane to refuse reconnection")
        } catch let DaemonClientError.transport(message) {
            #expect(message.contains("terminal"))
        } catch {
            Issue.record("expected the terminal pane-lane error, got \(error)")
        }
    }

    private func poll(
        _ timeout: TimeInterval = 2,
        condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }
}

/// Controlled XPC peer that returns valid replies for the small method set the
/// lane test drives and deliberately leaves selected methods unanswered.
///
/// `@unchecked Sendable`: libxpc owns the callback threads; `stateQueue`
/// serializes the only Swift mutable state, and XPC handles are thread-safe.
private final class LaneReplyPeer: @unchecked Sendable {
    private struct HeldRequest {
        let method: RPCMethod
        let requestId: UInt32
        let peer: xpc_connection_t
    }

    let clientPeer: xpc_connection_t

    private let listener: xpc_connection_t
    private var stalledMethods: Set<RPCMethod>
    private var heldNextMethods: Set<RPCMethod> = []
    private var heldRequests: [HeldRequest] = []
    private let invalidatingMethods: Set<RPCMethod>
    private let stateQueue = DispatchQueue(label: "com.deviceterm.tests.xpc-lane-peer")
    private var storedMethods: [RPCMethod] = []
    private var storedAuthenticatedSessionIds: [String] = []

    var receivedMethods: [RPCMethod] {
        stateQueue.sync { storedMethods }
    }

    var authenticatedSessionIds: [String] {
        stateQueue.sync { storedAuthenticatedSessionIds }
    }

    init(
        stalling methods: Set<RPCMethod> = [],
        invalidating invalidatingMethods: Set<RPCMethod> = []
    ) {
        stalledMethods = methods
        self.invalidatingMethods = invalidatingMethods
        let listener = xpc_connection_create(nil, nil)
        self.listener = listener
        clientPeer = xpc_connection_create_from_endpoint(xpc_endpoint_create(listener))
    }

    func stall(_ method: RPCMethod) {
        stateQueue.sync { _ = stalledMethods.insert(method) }
    }

    func holdNext(_ method: RPCMethod) {
        stateQueue.sync { _ = heldNextMethods.insert(method) }
    }

    func releaseHeld(_ method: RPCMethod) {
        let held: HeldRequest? = stateQueue.sync {
            guard let index = heldRequests.firstIndex(where: { $0.method == method }) else {
                return nil
            }
            return heldRequests.remove(at: index)
        }
        guard let held, let body = responseBody(for: held.method) else { return }
        sendResponse(id: held.requestId, body: body, to: held.peer)
    }

    func start() {
        xpc_connection_set_event_handler(listener) { [weak self] event in
            guard let self, xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
            let incoming = event
            xpc_connection_set_event_handler(incoming) { [weak self] message in
                self?.handle(message, on: incoming)
            }
            xpc_connection_resume(incoming)
        }
        xpc_connection_resume(listener)
    }

    func stop() {
        xpc_connection_cancel(clientPeer)
        xpc_connection_cancel(listener)
    }

    private func handle(_ message: xpc_object_t, on peer: xpc_connection_t) {
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return }
        var length = 0
        guard let pointer = xpc_dictionary_get_data(message, XPCWireKey.data, &length),
            length > 0,
            let envelope = try? RPCEnvelope.decode(Data(bytes: pointer, count: length)),
            let requestId = envelope.id,
            let methodName = envelope.method,
            let method = RPCMethod(rawValue: methodName)
        else { return }

        let shouldWait = stateQueue.sync {
            storedMethods.append(method)
            if method == .sessionAuthenticate,
                case let .params(data) = envelope.body,
                let params = try? JSONDecoder().decode(
                    SessionAuthenticateParams.self,
                    from: data
                ) {
                storedAuthenticatedSessionIds.append(params.sessionId)
            }
            if stalledMethods.contains(method) {
                return true
            }
            if heldNextMethods.remove(method) != nil {
                heldRequests.append(
                    HeldRequest(method: method, requestId: requestId, peer: peer)
                )
                return true
            }
            return false
        }
        guard !shouldWait else { return }
        if invalidatingMethods.contains(method) {
            xpc_connection_cancel(peer)
            return
        }
        guard let body = responseBody(for: method) else { return }
        sendResponse(id: requestId, body: body, to: peer)
    }

    private func responseBody(for method: RPCMethod) -> RPCEnvelope.Body? {
        let value: any Encodable
        switch method {
        case .sessionCreate:
            value = SessionCreateResponse(
                sessionId: UUID().uuidString,
                capability: "lane-test-capability",
                shortId: "LANE01",
                role: .agent
            )

        case .sessionAuthenticate:
            value = SessionAuthenticateResponse(success: true, role: .agent)

        case .daemonCapabilities:
            value = DaemonCapabilitiesResponse(
                role: .agent,
                allowedMethods: [],
                wireVersion: DaemonProtocolInfo.wireVersion,
                linkagePolicyVersion: LinkagePolicy.currentVersion
            )

        case .daemonPing:
            value = DaemonPingResponse(version: DaemonProtocolInfo.wireVersion, pid: 1)

        case .sessionClose:
            value = RPCAck(success: true)

        case .paneSubscribe:
            value = PaneSubscribeAck(success: true, subscriptionToken: UUID().uuidString)

        default:
            return nil
        }
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return .result(data)
    }

    private func sendResponse(
        id: UInt32,
        body: RPCEnvelope.Body,
        to peer: xpc_connection_t
    ) {
        let envelope = RPCEnvelope(id: id, type: .response, method: nil, body: body)
        guard let responseData = try? envelope.encode() else { return }
        let reply = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(reply, XPCWireKey.type, XPCWireKey.rpcValue)
        responseData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            xpc_dictionary_set_data(reply, XPCWireKey.data, base, responseData.count)
        }
        xpc_connection_send_message(peer, reply)
    }
}
