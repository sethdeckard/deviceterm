// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonTestSupport
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

// `TestClient`, `TestClientError`, and `tempSocketPath(prefix:)` live
// in `Support/`. This file owns the server-side smoke tests for the
// RPC plumbing only.

private func makePingEnvelope(id: UInt32) -> RPCEnvelope {
    RPCEnvelope(id: id, type: .request, method: "daemon.ping", body: .empty)
}

// MARK: - End-to-end ping round-trip

@Test
func pingReturnsVersionAndPid() async throws {
    let path = tempSocketPath()
    let server = RPCServer(
        socketPath: path,
        methods: DaemonMethods.defaultRegistry(
            sessionManager: SessionManager(),
            deviceCoordinator: DeviceCoordinator(),
            paneCoordinator: PaneCoordinator()
        )
    )
    try await server.start()
    defer { Task { await server.stop() } }

    // Give the listener a few ms to publish before the client connects.
    // (The DispatchSource starts up async, so `start()` returning doesn't
    // strictly guarantee the kernel has the socket ready, though in
    // practice it does on macOS.)
    try await Task.sleep(nanoseconds: 50_000_000)

    let client = try TestClient.connect(to: path)
    defer { client.close() }

    try client.send(makePingEnvelope(id: 1))
    let response = try client.receive()

    #expect(response.id == 1)
    #expect(response.type == .response)
    guard case let .result(bytes) = response.body else {
        Issue.record("expected .result body, got \(response.body)")
        return
    }
    let ping = try JSONDecoder().decode(DaemonMethods.PingResponse.self, from: bytes)
    #expect(ping.version == DaemonInfo.version)
    #expect(ping.pid == ProcessInfo.processInfo.processIdentifier)
}

// MARK: - Method-not-found response

@Test
func unknownMethodReturnsStructuredError() async throws {
    let path = tempSocketPath()
    let server = RPCServer(
        socketPath: path,
        methods: DaemonMethods.defaultRegistry(
            sessionManager: SessionManager(),
            deviceCoordinator: DeviceCoordinator(),
            paneCoordinator: PaneCoordinator()
        )
    )
    try await server.start()
    defer { Task { await server.stop() } }
    try await Task.sleep(nanoseconds: 50_000_000)

    let client = try TestClient.connect(to: path)
    defer { client.close() }

    let bogus = RPCEnvelope(id: 42, type: .request, method: "no.such.method", body: .empty)
    try client.send(bogus)
    let response = try client.receive()

    #expect(response.id == 42)
    #expect(response.type == .response)
    guard case let .error(rpcError) = response.body else {
        Issue.record("expected .error body, got \(response.body)")
        return
    }
    #expect(rpcError.code == RPCErrorCode.methodNotFound)
    #expect(rpcError.message.contains("no.such.method"))
}

// MARK: - Concurrent clients

@Test
func multipleClientsReceiveIndependentResponses() async throws {
    let path = tempSocketPath()
    let server = RPCServer(
        socketPath: path,
        methods: DaemonMethods.defaultRegistry(
            sessionManager: SessionManager(),
            deviceCoordinator: DeviceCoordinator(),
            paneCoordinator: PaneCoordinator()
        )
    )
    try await server.start()
    defer { Task { await server.stop() } }
    try await Task.sleep(nanoseconds: 50_000_000)

    let clientA = try TestClient.connect(to: path)
    let clientB = try TestClient.connect(to: path)
    defer {
        clientA.close()
        clientB.close()
    }

    try clientA.send(makePingEnvelope(id: 7))
    try clientB.send(makePingEnvelope(id: 99))
    let respA = try clientA.receive()
    let respB = try clientB.receive()
    #expect(respA.id == 7)
    #expect(respB.id == 99)
    // Give the server a moment to register both connections before
    // we observe activeConnectionCount.
    let active = await server.activeConnectionCount
    #expect(active >= 2)
}

// MARK: - Lifecycle

@Test
func stopUnlinksSocketAndRefusesNewConnections() async throws {
    let path = tempSocketPath()
    let server = RPCServer(
        socketPath: path,
        methods: DaemonMethods.defaultRegistry(
            sessionManager: SessionManager(),
            deviceCoordinator: DeviceCoordinator(),
            paneCoordinator: PaneCoordinator()
        )
    )
    try await server.start()
    try await Task.sleep(nanoseconds: 50_000_000)

    await server.stop()
    // Socket file should be gone.
    #expect(!FileManager.default.fileExists(atPath: path))
    // And a fresh connect to the same path should now fail.
    #expect(throws: (any Error).self) {
        _ = try UDSSocket.connectClient(to: path)
    }
}

@Test
func disconnectingBeforeReadingResponseDoesNotKillDaemon() async throws {
    // Without SO_NOSIGPIPE, a peer that closes between sending its
    // request and reading the response would terminate the daemon
    // with SIGPIPE the moment the response write hit the closed
    // socket. Hard to assert "process didn't die" directly inside
    // its own test, so the proof is "a second client can still
    // round-trip after we did the abandon-and-close dance with the
    // first one."
    let path = tempSocketPath()
    let server = RPCServer(
        socketPath: path,
        methods: DaemonMethods.defaultRegistry(
            sessionManager: SessionManager(),
            deviceCoordinator: DeviceCoordinator(),
            paneCoordinator: PaneCoordinator()
        )
    )
    try await server.start()
    defer { Task { await server.stop() } }
    try await Task.sleep(nanoseconds: 50_000_000)

    // First client: send + disconnect without reading. The server's
    // response write will hit EPIPE, which we want to surface as a
    // benign close, not a fatal signal.
    let abandoner = try TestClient.connect(to: path)
    try abandoner.send(makePingEnvelope(id: 1))
    abandoner.close()
    // Give the daemon a moment to attempt the response write.
    try await Task.sleep(nanoseconds: 100_000_000)

    // Second client: confirm the daemon is alive and responsive.
    let survivor = try TestClient.connect(to: path)
    defer { survivor.close() }
    try survivor.send(makePingEnvelope(id: 2))
    let response = try survivor.receive()
    #expect(response.id == 2)
    #expect(response.type == .response)
}

@Test
func startThrowsIfAlreadyStarted() async throws {
    let path = tempSocketPath()
    let server = RPCServer(
        socketPath: path,
        methods: DaemonMethods.defaultRegistry(
            sessionManager: SessionManager(),
            deviceCoordinator: DeviceCoordinator(),
            paneCoordinator: PaneCoordinator()
        )
    )
    try await server.start()
    defer { Task { await server.stop() } }
    await #expect(throws: RPCServerError.alreadyStarted) {
        try await server.start()
    }
}

// MARK: - Path safety

@Test
func bindListenerRejectsExistingPath() throws {
    // A non-socket file at the path is never clobbered: refuse.
    let path = tempSocketPath()
    FileManager.default.createFile(atPath: path, contents: Data())
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(throws: UDSSocketError.socketPathExists(path: path)) {
        _ = try UDSSocket.bindListener(at: path)
    }
}

@Test
func bindListenerReplacesStaleSocket() throws {
    // A daemon killed by SIGKILL leaves its socket file on disk with no
    // listener behind it. A fresh bind must unlink that stale socket and
    // succeed, or every future spawn wedges.
    let path = tempSocketPath()
    let stale = try UDSSocket.bindListener(at: path)
    Darwin.close(stale)  // drop the listener but leave the socket file
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(FileManager.default.fileExists(atPath: path))
    let fresh = try UDSSocket.bindListener(at: path)
    defer { Darwin.close(fresh) }
    #expect(fresh >= 0)
}

@Test
func bindListenerRejectsLiveListener() throws {
    // A *live* listener owns the path, so a second bind must refuse rather
    // than steal it (this is what distinguishes live from stale).
    let path = tempSocketPath()
    let live = try UDSSocket.bindListener(at: path)
    defer {
        Darwin.close(live)
        try? FileManager.default.removeItem(atPath: path)
    }
    #expect(throws: UDSSocketError.socketPathExists(path: path)) {
        _ = try UDSSocket.bindListener(at: path)
    }
}

@Test
func bindListenerRejectsOverlongPath() {
    // 104-byte name (one past macOS's 103 limit). The path doesn't
    // need to exist; the check is purely structural.
    let dir = NSTemporaryDirectory()
    let pad = String(repeating: "a", count: 200)  // > maxPathLength
    let path = dir + pad
    #expect(throws: (any Error).self) {
        _ = try UDSSocket.bindListener(at: path)
    }
}

// MARK: - Streaming subscriptions

/// Tracks whether a subscription's `onCancel` ran. Used by the
/// disconnect-cancellation test below.
private actor CancelTracker {
    private var calls: Int = 0
    var observed: Int { calls }
    func tick() { calls += 1 }
}

@Test
func subscriptionStreamsEventsCorrelatedByRequestId() async throws {
    // Hand-rolled registry: one subscription method that yields three
    // events then finishes. Verifies the canonical streaming shape:
    // initial .result, then .event frames sharing the request id and
    // carrying the handler-declared method name.
    let registry = MethodRegistry(
        handlers: [:],
        subscriptions: [
            "test.subscribe": .daemonWide { _, _ in
                let (stream, continuation) =
                    AsyncStream<MethodRegistry.SubscriptionEvent>.makeStream()
                Task {
                    do {
                        for tickIndex in 1...3 {
                            let payload = try JSONSerialization.data(
                                withJSONObject: ["n": NSNumber(value: tickIndex)],
                                options: []
                            )
                            continuation.yield(
                                MethodRegistry.SubscriptionEvent(
                                    method: "test.tick",
                                    params: payload
                                )
                            )
                        }
                    } catch {
                        Issue.record("test.tick payload encode failed: \(error)")
                    }
                    continuation.finish()
                }
                return MethodRegistry.SubscriptionResult(
                    initialResult: Data("{\"started\":true}".utf8),
                    events: stream,
                    onCancel: {}
                )
            }
        ]
    )
    let path = tempSocketPath()
    let server = RPCServer(socketPath: path, methods: registry)
    try await server.start()
    defer { Task { await server.stop() } }
    try await Task.sleep(nanoseconds: 50_000_000)

    let client = try TestClient.connect(to: path)
    defer { client.close() }
    try client.send(
        RPCEnvelope(
        id: 77,
        type: .request,
        method: "test.subscribe",
        body: .empty
    )
        )

    // Initial response with the handler's seed bytes.
    let initial = try client.receive()
    #expect(initial.id == 77)
    #expect(initial.type == .response)
    guard case let .result(initialBytes) = initial.body else {
        Issue.record("expected .result body, got \(initial.body)")
        return
    }
    let initialDict = try JSONSerialization.jsonObject(with: initialBytes) as? [String: Any]
    #expect((initialDict?["started"] as? NSNumber)?.boolValue == true)

    // Three .event frames, same id, ordered.
    var ticks: [Int] = []
    for _ in 0..<3 {
        let event = try client.receive()
        #expect(event.id == 77)
        #expect(event.type == .event)
        #expect(event.method == "test.tick")
        guard case let .params(eventBytes) = event.body else {
            Issue.record("expected .params body on event, got \(event.body)")
            continue
        }
        let dict = try JSONSerialization.jsonObject(with: eventBytes) as? [String: Any]
        if let n = (dict?["n"] as? NSNumber)?.intValue {
            ticks.append(n)
        }
    }
    #expect(ticks == [1, 2, 3])
}

@Test
func subscriptionOnCancelFiresWhenClientDisconnects() async throws {
    let tracker = CancelTracker()
    let registry = MethodRegistry(
        handlers: [:],
        subscriptions: [
            "test.subscribe": .daemonWide { _, _ in
                // Stream that never finishes naturally, so only the
                // client-disconnect path can stop it.
                let (stream, _) =
                    AsyncStream<MethodRegistry.SubscriptionEvent>.makeStream()
                let trackerRef = tracker
                return MethodRegistry.SubscriptionResult(
                    initialResult: Data("{}".utf8),
                    events: stream,
                    onCancel: {
                        Task { await trackerRef.tick() }
                    }
                )
            }
        ]
    )
    let path = tempSocketPath()
    let server = RPCServer(socketPath: path, methods: registry)
    try await server.start()
    defer { Task { await server.stop() } }
    try await Task.sleep(nanoseconds: 50_000_000)

    let client = try TestClient.connect(to: path)
    try client.send(
        RPCEnvelope(
        id: 1,
        type: .request,
        method: "test.subscribe",
        body: .empty
    )
        )
    _ = try client.receive()  // initial ack

    // Disconnect mid-subscription. The connection actor should
    // notice EOF, cancel the drain task, and fire onCancel.
    client.close()

    // Give the connection a moment to observe EOF and cascade the
    // cancel.
    try await Task.sleep(nanoseconds: 200_000_000)
    let count = await tracker.observed
    #expect(count >= 1)
}
