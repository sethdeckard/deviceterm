// SPDX-License-Identifier: GPL-3.0-or-later
//
// DaemonClientDeadlineTests: the upper bound on a daemon round-trip.
//
// A daemon that stops answering (a blocking CoreSimulator call on its actor,
// a `kill -STOP`) keeps its connection open, so nothing fails: the GUI simply
// waits. Foreground requests and the pane-subscribe handshake bound that wait,
// while the background `app.commands` handshake deliberately doesn't. These
// tests pin what the bound does and doesn't cover.
//
// Two shapes of bound live here, and the difference is what happens to a reply
// that arrives after the caller gave up. An ordinary request cancels its
// transport, discarding the reply, which costs nothing for a read. A call that
// mints daemon state can't do that (the reply names what it minted), so
// `session.create` runs under `Deadline.wait` and closes what it finds.
//
// The injected transports model a **silent peer**, not a transport that
// ignores cancellation. That distinction is what makes the cancel-the-loser
// bound work at all: the loser is cancelled and awaited, so a transport that
// refused to unwind would hang the race rather than expire it. The real XPC
// and UDS transports resume a parked continuation on cancellation
// (`XPCDaemonConnectionTests` and `UDSDaemonConnectionTests` pin that against
// real silent peers), and a `Task.sleep` here has the same property while
// putting nothing on a wire.

@testable import App
import DaemonProtocol
import Foundation
import Testing

@MainActor
struct DaemonClientDeadlineTests {
    /// A peer that accepts every request and answers only after `delay`,
    /// which each test sets on either side of the bound under test.
    ///
    /// `@unchecked Sendable` invariant: each test owns one instance and the
    /// only mutation is `methods`, appended on the main actor before the
    /// call suspends, then read after the awaited calls have returned.
    private final class SlowRequestTransport: DaemonRequestTransport, @unchecked Sendable {
        private(set) var methods: [String] = []
        var delay: UInt64
        /// Number of `session.authenticate` calls to refuse before accepting,
        /// modelling a create that lands but can't immediately be
        /// authenticated onto the connection. `.max` never accepts.
        var authenticateFailures = 0
        /// Sessions the daemon actually closed. Distinct from `methods`, which
        /// records the attempt: a `session.close` refused by the scope gate
        /// appears there but changes nothing, so only this proves cleanup.
        private(set) var closedSessions: [String] = []
        /// Mirrors the daemon's dispatcher gate: session-scoped methods are
        /// refused until this connection has authenticated. `session.close` is
        /// one of them, which is what makes cleaning up the very FIRST
        /// session's reply a two-step affair.
        private var authenticated = false

        init(delay: UInt64) {
            self.delay = delay
        }

        /// Just enough of a reply for the caller to decode. These tests are
        /// about timing, so any well-formed result for the method will do.
        private static func reply(for method: String) -> Data {
            switch RPCMethod(rawValue: method) {
            case .deviceAttach, .physicalDeviceAttach:
                let response = PaneCreateResponse(paneId: "P", scale: nil)
                return (try? JSONEncoder().encode(response)) ?? Data("{}".utf8)

            case .sessionCreate:
                let response = SessionCreateResponse(sessionId: "S", capability: "C")
                return (try? JSONEncoder().encode(response)) ?? Data("{}".utf8)

            case .sessionAuthenticate:
                let response = SessionAuthenticateResponse(success: true, role: .agent)
                return (try? JSONEncoder().encode(response)) ?? Data("{}".utf8)

            default:
                return Data("{}".utf8)
            }
        }

        func request(method: String, params: Data?) async throws -> Data {
            methods.append(method)
            try await Task.sleep(nanoseconds: delay)
            switch RPCMethod(rawValue: method) {
            case .sessionAuthenticate:
                if authenticateFailures > 0 {
                    if authenticateFailures != .max { authenticateFailures -= 1 }
                    throw DaemonClientError.daemon(code: -32_000, message: "refused")
                }
                authenticated = true

            case .sessionClose where !authenticated:
                throw DaemonClientError.daemon(
                    code: -32_001,
                    message: "session-scoped method requires an "
                        + "authenticated connection; call "
                        + "session.authenticate first"
                )

            case .sessionClose:
                let closed = params
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    .flatMap { $0?["sessionId"] as? String }
                if let closed { closedSessions.append(closed) }

            default:
                break
            }
            return Self.reply(for: method)
        }
    }

    /// The subscribe half of the same peer: parks the handshake, so a pane
    /// mirror can't hang on a `pane.subscribe` that never gets an ack.
    private final class SlowSubscribeTransport: DaemonSubscribeTransport, @unchecked Sendable {
        private let delay: UInt64

        init(delay: UInt64) {
            self.delay = delay
        }

        func subscribePane(paneId: String) async throws -> AsyncStream<PaneEvent> {
            try await Task.sleep(nanoseconds: delay)
            return AsyncStream { $0.finish() }
        }
    }

    /// A client whose default bound expires well inside the peer's delay and
    /// whose slow-method bound sits well outside it, so one fixture decides
    /// both halves of the allowance table.
    private func makeClient(
        peerDelay: UInt64 = 400_000_000,
        subscribe: DaemonSubscribeTransport? = nil
    ) -> (DaemonClient, SlowRequestTransport) {
        let transport = SlowRequestTransport(delay: peerDelay)
        let client = DaemonClient(injecting: transport, subscribe: subscribe)
        client.requestDeadlineNanos = 50_000_000
        client.slowRequestDeadlineNanos = 10_000_000_000
        return (client, transport)
    }

    @Test
    func anUnansweredRequestTimesOutNamingItsMethod() async {
        let (client, transport) = makeClient()
        do {
            _ = try await client.deviceList(scope: .all)
            Issue.record("expected the deadline to fire")
        } catch let DaemonClientError.timedOut(method) {
            #expect(method == RPCMethod.deviceList.rawValue)
        } catch {
            Issue.record("expected timedOut, got \(error)")
        }
        // The call was really sent: the deadline abandons the wait, it does
        // not refuse to issue the request.
        #expect(transport.methods == [RPCMethod.deviceList.rawValue])
    }

    @Test
    func theLifecycleMethodsOutliveTheDefaultBound() async {
        // Same peer, same delay: only the method changes. Both block inside
        // CoreSimulator for as long as the device takes, so they carry the
        // larger allowance and must still succeed here. Pinning them makes
        // shortening the allowance later a deliberate edit rather than a
        // silent regression.
        let (client, _) = makeClient()
        await #expect(throws: Never.self) {
            try await client.bootDevice(udid: "U", sessionId: "S", capability: "C")
        }
        await #expect(throws: Never.self) { try await client.shutdownDevice(udid: "U") }
    }

    @Test
    func aTimedOutSessionCreateClosesTheSessionItNeverSaw() async {
        // The capability leaves the daemon exactly once, so a reply the client
        // stopped waiting for can't just be dropped: it names a session no one
        // else can, and an omitting `restoreBatch` can't reap it on this
        // connection. The wait ends on time and the late reply is closed.
        let (client, transport) = makeClient()
        do {
            _ = try await client.createSession(label: nil, name: nil, role: .agent)
            Issue.record("expected the deadline to fire")
        } catch let DaemonClientError.timedOut(method) {
            #expect(method == RPCMethod.sessionCreate.rawValue)
        } catch {
            Issue.record("expected timedOut, got \(error)")
        }
        // The cleanup rides the same slow peer, so give it room to answer.
        client.requestDeadlineNanos = 5_000_000_000
        // It was the FIRST session on this connection, so nothing had
        // authenticated yet: the daemon refuses the session-scoped close until
        // the cleanup authenticates with the capability from the very reply it
        // is discarding. Asserting the close the daemon ACCEPTED (rather than
        // the one the client attempted) is what makes this bite: without the
        // recovery the first attempt -32001s and the session survives.
        let closed = await poll { transport.closedSessions == ["S"] }
        #expect(closed, "the unclaimed session was never closed: \(transport.methods)")
        #expect(transport.methods.contains(RPCMethod.sessionAuthenticate.rawValue))
    }

    @Test
    func aCreateWhoseAuthenticationBlipsClosesTheSessionItMade() async {
        // The create landed, so the session and its one-time capability
        // exist, but authentication failed and the caller is about to get an
        // error instead of them. Nothing would ever name that session again,
        // so it is closed on the way out. The blip is transient here, which is
        // the recoverable shape: the discard's own authenticate succeeds.
        let (client, transport) = makeClient(peerDelay: 0)
        transport.authenticateFailures = 1
        await #expect(throws: (any Error).self) {
            _ = try await client.createSession(label: nil, name: nil, role: .agent)
        }
        let closed = await poll { transport.closedSessions == ["S"] }
        #expect(closed, "the unauthenticated session was never closed: \(transport.methods)")
    }

    @Test
    func aCreateWhoseCapabilityIsRefusedOutrightCannotBeCleanedUp() async {
        // The corner with no client-side recovery, pinned so it is a known
        // limit rather than a surprise. Every way to remove a session is
        // session-scoped; a first create leaves the connection with no other
        // principal to borrow; and the only credential that could authorize
        // the close is the one the daemon keeps refusing. The session survives
        // until the next connection epoch, and the client says so in the log
        // rather than pretending it cleaned up.
        let (client, transport) = makeClient(peerDelay: 0)
        transport.authenticateFailures = .max
        await #expect(throws: (any Error).self) {
            _ = try await client.createSession(label: nil, name: nil, role: .agent)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(transport.closedSessions.isEmpty)
        // It tried, and the daemon refused: not a path that silently skips.
        #expect(transport.methods.contains(RPCMethod.sessionClose.rawValue))
    }

    /// Poll until `condition` holds or the bound expires, so a test fails
    /// rather than hangs when a cleanup never runs.
    private func poll(_ condition: () -> Bool, within seconds: Double = 3.0) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    @Test
    func anUnansweredPaneSubscribeTimesOut() async {
        // The handshake reaches the transport without going through
        // `request`, so it needs its own bound: without one a pane whose
        // subscribe is never acked mirrors nothing, forever.
        let (client, _) = makeClient(subscribe: SlowSubscribeTransport(delay: 400_000_000))
        do {
            _ = try await client.subscribePane(paneId: "P")
            Issue.record("expected the deadline to fire")
        } catch let DaemonClientError.timedOut(method) {
            #expect(method == RPCMethod.paneSubscribe.rawValue)
        } catch {
            Issue.record("expected timedOut, got \(error)")
        }
    }

    @Test
    func aTimeoutReadsAsPlainTextInThePlaceholder() {
        // What a failed attach actually shows: the pending pane renders
        // `ErrorText.describing` of whatever threw.
        let text = ErrorText.describing(
            DaemonClientError.timedOut(method: RPCMethod.deviceAttach.rawValue)
        )
        #expect(text.contains("timed out"))
        #expect(text.contains(RPCMethod.deviceAttach.rawValue))
    }
}
