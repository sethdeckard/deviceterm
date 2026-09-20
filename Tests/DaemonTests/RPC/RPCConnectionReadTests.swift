// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonTestSupport
import Foundation
import os
import Testing

/// How a connection reads its socket while a handler is slow.
///
/// The read source is level-triggered. Left resumed while the actor is
/// suspended inside a handler, it fires on every turn of its queue for as
/// long as bytes sit unread, and each firing costs work that reads nothing.
/// The connection holds the source off until it has drained the socket, so a
/// peer that keeps writing costs one firing per drain, and the frames it
/// wrote still come back in order once the handler returns.
struct RPCConnectionReadTests {
    /// Parks the `test.park` handler until the test releases it, and tells
    /// the test when the handler has entered, so a burst sent afterwards is
    /// known to arrive while the connection's pump is suspended inside it.
    private actor Park {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        private var entered = false

        func wait() async {
            entered = true
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        /// Whether the handler entered within the bound. Bounded so a read or
        /// dispatch regression that never runs the handler fails the test
        /// instead of hanging it.
        func awaitEntry(timeoutSeconds: Double = 5) async -> Bool {
            let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
            while !entered, Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return entered
        }

        func release() {
            released = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    private struct Harness {
        let path: String
        let server: RPCServer
        let park: Park
        let firings: OSAllocatedUnfairLock<Int>

        static func start() async throws -> Harness {
            let park = Park()
            let firings = OSAllocatedUnfairLock(initialState: 0)
            let registry = MethodRegistry(handlers: [
                "test.park": .daemonWide { _ in
                    await park.wait()
                    return Data("{}".utf8)
                },
                "test.echo": .daemonWide { params in params }
            ])
            let path = tempSocketPath(prefix: "deviceterm-read")
            let server = RPCServer(
                socketPath: path,
                methods: registry,
                readEventObserver: { _ in firings.withLock { $0 += 1 } }
            )
            try await server.start()
            try await Task.sleep(nanoseconds: 50_000_000)
            return Harness(path: path, server: server, park: park, firings: firings)
        }

        func stop() async {
            await park.release()
            await server.stop()
        }
    }

    private func request(_ id: UInt32, _ method: String) -> RPCEnvelope {
        RPCEnvelope(
            id: id,
            type: .request,
            method: method,
            body: .params(Data("{\"n\":\(id)}".utf8))
        )
    }

    @Test
    func framesSentWhileAHandlerIsParkedAreAnsweredInOrder() async throws {
        let harness = try await Harness.start()
        defer { Task { await harness.stop() } }
        let client = try TestClient.connect(to: harness.path)
        defer { client.close() }

        try client.send(request(1, "test.park"))
        try #require(await harness.park.awaitEntry(), "the parked handler never started")
        for id in 2...6 as ClosedRange<UInt32> {
            try client.send(request(id, "test.echo"))
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        await harness.park.release()

        var ids: [UInt32?] = []
        for _ in 1...6 {
            ids.append(try client.receive(timeoutSeconds: 5).id)
        }
        #expect(ids == [1, 2, 3, 4, 5, 6])
    }

    @Test
    func aParkedHandlerFiresTheReadSourceOncePerDrainNotPerQueueTurn() async throws {
        let harness = try await Harness.start()
        defer { Task { await harness.stop() } }
        let client = try TestClient.connect(to: harness.path)
        defer { client.close() }

        try client.send(request(1, "test.park"))
        try #require(await harness.park.awaitEntry(), "the parked handler never started")
        for id in 2...6 as ClosedRange<UInt32> {
            try client.send(request(id, "test.echo"))
        }
        // Long enough that a source left resumed would have fired thousands
        // of times against the unread bytes.
        try await Task.sleep(nanoseconds: 500_000_000)
        let firingsWhileParked = harness.firings.withLock { $0 }
        #expect(firingsWhileParked >= 1)
        #expect(
            firingsWhileParked <= 6,
            "the source fired \(firingsWhileParked) times for six writes behind a parked handler"
        )

        await harness.park.release()
        for _ in 1...6 {
            _ = try client.receive(timeoutSeconds: 5)
        }
    }

    @Test
    func aPeerClosingMidBurstClosesTheConnection() async throws {
        let harness = try await Harness.start()
        defer { Task { await harness.stop() } }
        let client = try TestClient.connect(to: harness.path)

        try client.send(request(1, "test.park"))
        try #require(await harness.park.awaitEntry(), "the parked handler never started")
        try client.send(request(2, "test.echo"))
        client.close()
        try await Task.sleep(nanoseconds: 100_000_000)
        await harness.park.release()

        var remaining = await harness.server.activeConnectionCount
        for _ in 0..<50 where remaining != 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
            remaining = await harness.server.activeConnectionCount
        }
        #expect(remaining == 0)
    }
}
