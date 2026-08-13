// SPDX-License-Identifier: GPL-3.0-or-later
//
// DaemonClientUnresponsiveTests: turning expired deadlines into the one
// signal a user can act on.
//
// A bounded call that expires says something went unanswered; it does not say
// the helper has stopped answering, because a single call can run long for
// reasons of its own. What separates the two is *consecutive* expiries with no
// reply in between, and these pin that distinction: what raises the signal,
// what counts as the reply that clears it, and that a helper answering nothing
// keeps raising it rather than reporting the condition once and going quiet.

@testable import App
import DaemonProtocol
import Foundation
import Testing

@MainActor
struct DaemonClientUnresponsiveTests {
    /// A peer that answers or stays silent per call, scripted from the front
    /// of a queue so a test can spell out a streak and its interruptions.
    ///
    /// `@unchecked Sendable` invariant: one instance per test, its queue
    /// written on the main actor before the calls run and read only from
    /// inside them.
    private final class ScriptedTransport: DaemonRequestTransport, @unchecked Sendable {
        /// What one call gets. `refuses` is a reply as much as `answers` is,
        /// which is the distinction two of these tests turn on.
        enum Reply {
            case answers
            case refuses
            case silent
        }

        /// One entry per call, consumed from the front. An empty queue
        /// answers, so a test only writes the part it cares about.
        var script: [Reply] = []

        /// Just enough of a reply for the caller to decode; these tests are
        /// about the accounting, so any well-formed result will do.
        private static func reply(for method: String) -> Data {
            switch RPCMethod(rawValue: method) {
            case .deviceAttach, .physicalDeviceAttach:
                let response = PaneCreateResponse(paneId: "P", scale: nil)
                return (try? JSONEncoder().encode(response)) ?? Data("{}".utf8)

            case .daemonPing:
                // Matching version, so `connect()`'s handshake succeeds and the
                // client reaches the point where it seeds the connection it
                // will name in the signal.
                let response = DaemonPingResponse(
                    version: DaemonProtocolInfo.wireVersion,
                    pid: 1
                )
                return (try? JSONEncoder().encode(response)) ?? Data("{}".utf8)

            case .deviceList:
                return Data("[]".utf8)

            default:
                return Data("{}".utf8)
            }
        }

        func request(method: String, params: Data?) async throws -> Data {
            switch script.isEmpty ? .answers : script.removeFirst() {
            case .answers:
                return Self.reply(for: method)

            case .refuses:
                throw DaemonClientError.daemon(code: -32_602, message: "refused")

            case .silent:
                // Silent, not uncooperative: the bound cancels the loser of
                // its race and awaits it, so a peer that refused to unwind
                // would hang instead of expiring.
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return Data("{}".utf8)
            }
        }
    }

    /// A client whose bound expires almost immediately, so a silent call costs
    /// milliseconds rather than the production fifteen seconds.
    private func makeClient() -> (DaemonClient, ScriptedTransport) {
        let transport = ScriptedTransport()
        let client = DaemonClient(injecting: transport)
        client.requestDeadlineNanos = 20_000_000
        return (client, transport)
    }

    /// Drive `deviceList` and swallow the outcome; every test here is about
    /// the accounting, not the reply.
    private func call(_ client: DaemonClient) async {
        _ = try? await client.deviceList(scope: .all)
    }

    @Test
    func aStreakOfUnansweredCallsReportsTheHelperUnresponsive() async {
        let (client, transport) = makeClient()
        transport.script = [.silent, .silent]
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        await call(client)
        #expect(reports == 0, "one expiry is not evidence on its own")
        await call(client)
        #expect(reports == 1)
    }

    @Test
    func anAnswerBetweenTwoExpiriesBreaksTheStreak() async {
        // The condition is a helper that has stopped answering, so a reply in
        // the middle means it hasn't: two expiries around one are two
        // isolated slow calls, which is a different thing and not one a user
        // should be interrupted about.
        let (client, transport) = makeClient()
        transport.script = [.silent, .answers, .silent]
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        for _ in 0..<3 { await call(client) }
        #expect(reports == 0)
    }

    @Test
    func aRefusalBreaksTheStreakTooBecauseItIsStillAReply() async {
        // A helper that rejects a request is answering. Counting a refusal as
        // silence would let an expiry, a prompt rejection, and another expiry
        // diagnose a helper the user can plainly see responding.
        let (client, transport) = makeClient()
        transport.script = [.silent, .refuses, .silent]
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        for _ in 0..<3 { await call(client) }
        #expect(reports == 0)
    }

    @Test
    func aPermanentlySilentHelperKeepsReporting() async {
        // The reported case: nothing answers again, so expiries are the only
        // events left. Reporting just the first would give the observer one
        // signal for the whole condition, and a user who chose to wait would
        // never be asked again. Suppressing the repeats belongs to the
        // observer, which knows what it is already showing.
        let (client, transport) = makeClient()
        transport.script = [.silent, .silent, .silent, .silent, .silent]
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        for _ in 0..<5 { await call(client) }
        #expect(reports == 4)
    }

    @Test
    func aSecondStreakAfterRecoveryReportsAgain() async {
        // The count clears on an answer, so a helper that recovers and then
        // goes quiet again has to rebuild the streak from zero rather than
        // reporting off the tail of the old one.
        let (client, transport) = makeClient()
        transport.script = [.silent, .silent, .answers, .silent]
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        for _ in 0..<4 { await call(client) }
        #expect(reports == 1, "the answer reset the count, so the last expiry is only the first")
    }

    @Test
    func aCallThatSkipsTheSharedBoundStillClearsAStreak() async {
        // The attaches and `session.create` bound themselves rather than going
        // through the shared wrapper, because cancelling them would discard
        // the reply naming what they minted. An attach answering promptly is
        // as much proof the helper is alive as any other reply, so it has to
        // clear the count too, or a streak would outlive its cause.
        let (client, transport) = makeClient()
        transport.script = [.silent]
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        await call(client)
        _ = try? await client.attachDevice(sessionId: "S", capability: "C", udid: "U")
        await call(client)
        #expect(reports == 0)
    }

    @Test
    func theSignalNamesTheConnectionTheUnansweredCallsWereGoingTo() async throws {
        // The value, not just that one is passed: it is what fences the kill,
        // so a wrong number either spares the peer that was diagnosed or
        // targets one that wasn't. The reconnect handler covers every later
        // connection but deliberately skips the first, so this pins the seed
        // that covers a helper going quiet on the connection it started on.
        //
        // A mach service name nothing vends: `connect()` builds a real client
        // connection, which is what assigns the generation, and never sends on
        // it, because the scripted transport answers every request instead.
        let transport = ScriptedTransport()
        let client = DaemonClient(
            injecting: transport,
            machServiceName: "com.deviceterm.test.no-such-service"
        )
        client.requestDeadlineNanos = 20_000_000
        try await client.connect()
        var named: [Int] = []
        client.onUnresponsive = { named.append($0) }
        transport.script = [.silent, .silent]
        await call(client)
        await call(client)
        #expect(named == [1], "the connection `connect()` established")
    }

    @Test
    func aRefusedSelfBoundCallClearsAStreakToo() async {
        // The same rule on the same path: a refused attach is a reply. This is
        // the shape that made classifying failures in one place worth doing,
        // because the self-bound path and the shared bound have to agree and
        // there is nothing in the types to make them.
        let (client, transport) = makeClient()
        transport.script = [.silent, .refuses, .silent]
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        await call(client)
        _ = try? await client.attachDevice(sessionId: "S", capability: "C", udid: "U")
        await call(client)
        #expect(reports == 0)
    }
}
