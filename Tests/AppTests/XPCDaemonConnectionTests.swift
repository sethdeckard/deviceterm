// SPDX-License-Identifier: GPL-3.0-or-later
//
// XPCDaemonConnectionTests: the transport-level fences added for the
// wire-version-mismatch remediation, exercised against a CONTROLLED silent
// peer (an anonymous XPC listener that accepts a connection but never replies)
// so a request genuinely PARKS. That lets each test assert the specific
// outcome: the gate's own error, no demand-connect for the bootstrap
// shutdown, quiescence of in-flight traffic, and real cancellation with
// pending-state cleanup, rather than a service-unavailable invalidation that
// would pass even with the implementation removed.

@testable import App
import DaemonProtocol
import Foundation
import Testing
@preconcurrency import XPC

@MainActor
struct XPCDaemonConnectionTests {
    /// An anonymous listener that accepts a peer connection and then ignores
    /// every message (never replies), plus the client-side peer to hand the
    /// connection. Keep the returned `listener` alive for the test's duration,
    /// or the peer invalidates and requests error instead of parking.
    private func makeSilentPeer() -> (peer: xpc_connection_t, listener: xpc_connection_t) {
        let listener = xpc_connection_create(nil, nil)
        xpc_connection_set_event_handler(listener) { event in
            if xpc_get_type(event) == XPC_TYPE_CONNECTION {
                xpc_connection_set_event_handler(event) { _ in }  // accept, never reply
                xpc_connection_resume(event)
            }
        }
        xpc_connection_resume(listener)
        let endpoint = xpc_endpoint_create(listener)
        let peer = xpc_connection_create_from_endpoint(endpoint)
        xpc_connection_set_event_handler(peer) { _ in }
        xpc_connection_resume(peer)
        return (peer, listener)
    }

    private func poll(_ timeout: Double = 2.0, _ cond: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await cond()
    }

    // MARK: - Gate: only daemon.shutdown passes; ordinary traffic is refused

    @Test
    func incompatibleTransportRefusesOrdinaryRequestWithGateError() async {
        // No live connection needed: the gate throws before any demand-connect.
        // Asserting the SPECIFIC "incompatible" message proves the gate fired:
        // without it, `request` would connect to a bogus service and park (hang),
        // not throw this error.
        let conn = XPCDaemonConnection(machServiceName: "com.example.deviceterm.test.nonexistent")
        await conn.markIncompatible(expectedGeneration: 0)  // gen 0 = unconnected/test peer
        do {
            _ = try await conn.request(method: RPCMethod.sessionCreate.rawValue, params: nil)
            Issue.record("expected the incompatible-transport gate refusal")
        } catch let DaemonClientError.transport(message) {
            #expect(message.contains("incompatible"))
        } catch {
            Issue.record("expected the transport gate error, got \(error)")
        }
    }

    @Test
    func incompatibleTransportRefusesSubscribeWithGateError() async {
        let conn = XPCDaemonConnection(machServiceName: "com.example.deviceterm.test.nonexistent")
        await conn.markIncompatible(expectedGeneration: 0)  // gen 0 = unconnected/test peer
        do {
            _ = try await conn.subscribeRaw(method: RPCMethod.appCommands.rawValue, params: nil)
            Issue.record("expected the incompatible-transport gate refusal")
        } catch let DaemonClientError.transport(message) {
            #expect(message.contains("incompatible"))
        } catch {
            Issue.record("expected the transport gate error, got \(error)")
        }
    }

    // MARK: - Shutdown does not demand-connect a replacement

    @Test
    func incompatibleShutdownDoesNotDemandConnectAReplacement() async {
        // With no live peer, the bootstrap `daemon.shutdown` passes the gate but
        // must NOT demand-connect (which could launch + terminate the UPDATED
        // replacement daemon): it aborts because the mismatched instance is gone.
        let conn = XPCDaemonConnection(machServiceName: "com.example.deviceterm.test.nonexistent")
        await conn.markIncompatible(expectedGeneration: 0)  // gen 0 = unconnected/test peer
        do {
            _ = try await conn.request(method: RPCMethod.daemonShutdown.rawValue, params: nil)
            Issue.record("expected the shutdown to abort with no peer")
        } catch let DaemonClientError.transport(message) {
            #expect(message.contains("already disconnected") || message.contains("nothing to shut down"))
        } catch {
            Issue.record("expected the no-peer abort, got \(error)")
        }
    }

    // MARK: - Incompatible connections quiesce in-flight traffic

    @Test
    func markIncompatibleQuiescesInFlightRequest() async {
        let (peer, listener) = makeSilentPeer()
        let conn = XPCDaemonConnection(machServiceName: "unused")
        await conn.setTestConnection(peer)
        // A request that parks on the silent peer (no reply ever comes).
        let task = Task { try await conn.request(method: RPCMethod.daemonPing.rawValue, params: nil) }
        let parked = await poll { await conn.pendingRequestCountForTesting == 1 }
        #expect(parked)

        await conn.markIncompatible(expectedGeneration: 0)  // gen 0 = unconnected/test peer

        do {
            _ = try await task.value
            Issue.record("expected the in-flight request to be quiesced")
        } catch let DaemonClientError.transport(message) {
            #expect(message.contains("incompatible"))
        } catch {
            Issue.record("expected the quiesce error, got \(error)")
        }
        #expect(await conn.pendingRequestCountForTesting == 0)
        withExtendedLifetime(listener) {}
    }

    @Test
    func markIncompatibleQuiescesEvenWhenGenerationMismatched() async {
        // A failed generation fence (the connection is a REPLACEMENT) must still
        // terminalize the transport (the in-flight request is quiesced and the
        // pending state cleared) so nothing keeps running over a connection that
        // will never complete a reconnect handshake. Only the shutdown SEND is
        // gated by the generation (reported via the return value).
        let (peer, listener) = makeSilentPeer()
        let conn = XPCDaemonConnection(machServiceName: "unused")
        await conn.setTestConnection(peer)
        let task = Task { try await conn.request(method: RPCMethod.daemonPing.rawValue, params: nil) }
        let parked = await poll { await conn.pendingRequestCountForTesting == 1 }
        #expect(parked)

        // A generation that does NOT match the connection (models a replacement).
        let pinned = await conn.markIncompatible(expectedGeneration: 999)
        #expect(!pinned)  // not the pinned instance: shutdown must not be sent

        do {
            _ = try await task.value
            Issue.record("expected the in-flight request to be quiesced anyway")
        } catch let DaemonClientError.transport(message) {
            #expect(message.contains("incompatible"))
        } catch {
            Issue.record("expected the quiesce error, got \(error)")
        }
        #expect(await conn.pendingRequestCountForTesting == 0)  // quiesced despite mismatch
        withExtendedLifetime(listener) {}
    }

    // MARK: - Pending requests are cancellable and clean up state

    @Test
    func pendingRequestIsCancellableAndCleansUpPendingState() async {
        let (peer, listener) = makeSilentPeer()
        let conn = XPCDaemonConnection(machServiceName: "unused")
        await conn.setTestConnection(peer)
        let task = Task { try await conn.request(method: RPCMethod.daemonPing.rawValue, params: nil) }
        let parked = await poll { await conn.pendingRequestCountForTesting == 1 }
        #expect(parked)  // genuinely parked: the silent peer never replies

        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected CancellationError")
        } catch is CancellationError {
            // Exactly the cancellation path: proves the continuation is
            // cancellation-aware (without it the task would hang forever).
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
        #expect(await conn.pendingRequestCountForTesting == 0)  // pending-state cleaned up
        withExtendedLifetime(listener) {}
    }
}
