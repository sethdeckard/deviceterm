// SPDX-License-Identifier: GPL-3.0-or-later
//
// DaemonClientUnresponsiveTests: turning expired deadlines into the one
// signal a user can act on.
//
// A bounded call that expires says something went unanswered; it does not say
// the helper has stopped answering, because a single call can run long for
// reasons of its own, and two of them landing together says only that two
// things were slow at once. So an expiry asks rather than concludes: it sends a
// `daemon.ping` to the same connection, and only silence there is reported.
// These pin what the probe is fenced to (one connection, one in flight, one
// verdict), what counts as the reply that calls it off, and what rearms it.

@testable import App
import DaemonProtocol
import Foundation
import Testing

@MainActor
struct DaemonClientUnresponsiveTests {
    /// A peer that answers or stays silent per call, scripted from the front of
    /// a queue so a test can spell out an expiry and what the probe behind it
    /// meets. `daemon.ping` draws from its own queue, because the probe is the
    /// thing under test and scripting it positionally would make every test
    /// depend on how many calls the client happened to make.
    ///
    /// An actor rather than a lock: one test drives three calls concurrently,
    /// and consuming the queue from several of them at once is a data race the
    /// isolation removes outright.
    private actor ScriptedTransport: DaemonRequestTransport {
        /// What one call gets. `refuses` is a reply as much as `answers` is,
        /// which is the distinction several of these tests turn on, and `fails`
        /// is neither: a transport loss says the connection went away.
        enum Reply {
            case answers
            case refuses
            case silent
            case fails
        }

        /// One entry per non-ping call, consumed from the front. An empty queue
        /// answers, so a test only writes the part it cares about.
        private var script: [Reply] = []
        /// The same, for `daemon.ping`.
        private var pingScript: [Reply] = []
        private var pingCount = 0

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

        func script(_ replies: [Reply]) {
            script = replies
        }

        func scriptPing(_ replies: [Reply]) {
            pingScript = replies
        }

        /// Pings seen so far. How "concurrent expiries share one probe" is
        /// checked: the reports alone can't tell one probe from three that
        /// happened to agree.
        func pingsSeen() -> Int {
            pingCount
        }

        func request(method: String, params: Data?) async throws -> Data {
            let reply: Reply
            if RPCMethod(rawValue: method) == .daemonPing {
                pingCount += 1
                reply = pingScript.isEmpty ? .answers : pingScript.removeFirst()
            } else {
                reply = script.isEmpty ? .answers : script.removeFirst()
            }
            switch reply {
            case .answers:
                return Self.reply(for: method)

            case .refuses:
                throw DaemonClientError.daemon(code: -32_602, message: "refused")

            case .fails:
                throw DaemonClientError.transport("connection went away")

            case .silent:
                // Silent, not uncooperative: the bound cancels the loser of
                // its race and awaits it, so a peer that refused to unwind
                // would hang instead of expiring.
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return Data("{}".utf8)
            }
        }
    }

    /// The pane peer, which is a separate connection with its own generation.
    /// Answers or stays silent for the whole test; the pane-lane tests only
    /// need one subscribe each.
    private actor ScriptedSubscribeTransport: DaemonSubscribeTransport {
        private let isSilent: Bool

        init(silent: Bool) {
            isSilent = silent
        }

        func subscribePane(paneId: String) async throws -> AsyncStream<PaneEvent> {
            if isSilent {
                try await Task.sleep(nanoseconds: 10_000_000_000)
            }
            return AsyncStream { $0.finish() }
        }
    }

    /// A client whose bound expires almost immediately, so a silent call costs
    /// milliseconds rather than the production fifteen seconds. The probe takes
    /// the same bound, so a full expiry-then-probe sequence is about forty.
    private func makeClient(
        paneSubscribe: ScriptedSubscribeTransport? = nil
    ) -> (DaemonClient, ScriptedTransport) {
        let transport = ScriptedTransport()
        let client = DaemonClient(injecting: transport, subscribe: paneSubscribe)
        client.requestDeadlineNanos = 20_000_000
        return (client, transport)
    }

    /// Drive `deviceList` and swallow the outcome; every test here is about
    /// the accounting, not the reply.
    private func call(_ client: DaemonClient) async {
        _ = try? await client.deviceList(scope: .all)
    }

    /// Long enough for a probe started by the last call to have finished. Used
    /// where a test asserts that nothing was reported, which otherwise passes
    /// for the wrong reason.
    private func waitOutTheProbe() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    @Test
    func anUnansweredCallProbesBeforeAnythingIsReported() async {
        // The point of the change: one expiry is a question, not a verdict. It
        // costs a ping to answer, and the ping answering means nothing is
        // reported at all.
        let (client, transport) = makeClient()
        await transport.script([.silent])
        await transport.scriptPing([.answers])
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        await call(client)
        await waitOutTheProbe()
        #expect(reports == 0, "the helper answered the ping, so it is answering")
        #expect(await transport.pingsSeen() == 1)
    }

    @Test
    func anExpiryWhoseProbeGoesUnansweredReportsTheHelper() async {
        let (client, transport) = makeClient()
        await transport.script([.silent])
        await transport.scriptPing([.silent])
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        await call(client)
        await waitOutTheProbe()
        #expect(reports == 1)
    }

    @Test
    func aRefusedProbeIsStillAReply() async {
        // A helper that rejects the ping is answering it. Counting a refusal as
        // silence would diagnose a helper the user can plainly see responding.
        let (client, transport) = makeClient()
        await transport.script([.silent])
        await transport.scriptPing([.refuses])
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        await call(client)
        await waitOutTheProbe()
        #expect(reports == 0)
    }

    @Test
    func aProbeLostToTheTransportDecidesNothing() async {
        // Neither silence nor an answer: the connection went away, which the
        // next send recovers. Reporting here would blame a wedge for what is
        // about to fix itself.
        let (client, transport) = makeClient()
        await transport.script([.silent])
        await transport.scriptPing([.fails])
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        await call(client)
        await waitOutTheProbe()
        #expect(reports == 0)
    }

    @Test
    func concurrentExpiriesShareOneProbe() async {
        // The false-prompt case that motivated the probe. Three calls expiring
        // together used to be three votes toward a verdict; now they are three
        // callers asking the same question, which is worth asking once.
        let (client, transport) = makeClient()
        await transport.script([.silent, .silent, .silent])
        await transport.scriptPing([.silent])
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        async let first: Void = call(client)
        async let second: Void = call(client)
        async let third: Void = call(client)
        _ = await (first, second, third)
        await waitOutTheProbe()
        #expect(await transport.pingsSeen() == 1, "one health check, not one per expiry")
        #expect(reports == 1)
    }

    @Test
    func aReplyThatLandsDuringTheProbeCallsItOff() async {
        // The probe asks whether anything is coming back. Something did, from
        // another call, while it was still waiting. That answers the question
        // it was sent to ask, so its own silence is no longer evidence.
        let (client, transport) = makeClient()
        await transport.script([.silent, .answers])
        await transport.scriptPing([.silent])
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        await call(client)
        await call(client)
        await waitOutTheProbe()
        #expect(reports == 0)
    }

    @Test
    func aPermanentlySilentHelperIsReportedOnceForItsConnection() async {
        // Nothing answers again, so expiries are the only events left. The
        // first is probed and reported; re-probing the same connection would
        // ask a question already answered, and re-reporting would stack
        // prompts on a user who has one open.
        let (client, transport) = makeClient()
        await transport.script([.silent, .silent, .silent, .silent, .silent])
        await transport.scriptPing([.silent, .silent, .silent, .silent, .silent])
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        for _ in 0..<5 { await call(client) }
        await waitOutTheProbe()
        #expect(reports == 1)
        #expect(await transport.pingsSeen() == 1)
    }

    @Test
    func anAnswerRearmsDetection() async {
        // A helper that comes back has earned a fresh verdict if it goes quiet
        // later, so the reply clears the report that was suppressing one.
        let (client, transport) = makeClient()
        await transport.script([.silent, .answers, .silent])
        await transport.scriptPing([.silent, .silent])
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        await call(client)
        await waitOutTheProbe()
        #expect(reports == 1)
        await call(client)
        await call(client)
        await waitOutTheProbe()
        #expect(reports == 2, "the answer in between made the second silence its own condition")
    }

    @Test
    func rearmingAsksAgainAboutTheSameConnection() async {
        // What the recovery coordinator uses when it declines a verdict or
        // finishes with one: nothing about the helper changed, but the observer
        // is ready to be told again.
        let (client, transport) = makeClient()
        await transport.script([.silent, .silent, .silent])
        await transport.scriptPing([.silent, .silent])
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        await call(client)
        await waitOutTheProbe()
        #expect(reports == 1)
        await call(client)
        await waitOutTheProbe()
        #expect(reports == 1, "the same connection is not re-reported on its own")
        client.rearmUnresponsiveDetection()
        await call(client)
        await waitOutTheProbe()
        #expect(reports == 2)
    }

    @Test
    func aReconnectDuringTheProbeThrowsAwayItsVerdict() async {
        // A verdict about the peer that went away says nothing about the one
        // that replaced it. Left standing, it would report a fresh helper
        // unresponsive and fence a kill to a connection nobody diagnosed.
        let (client, transport) = makeClient()
        await transport.script([.silent])
        await transport.scriptPing([.silent])
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        await call(client)
        client.adoptReconnectedConnection(2)
        await waitOutTheProbe()
        #expect(reports == 0)
    }

    @Test
    func aPaneLaneExpiryDiagnosesNothing() async {
        // The pane peer is its own connection. A subscribe that goes unanswered
        // says the pane peer is quiet, which is not what the probe would go on
        // to ask the control peer about, and the pane peer has its own retry
        // loop for it.
        let (client, transport) = makeClient(
            paneSubscribe: ScriptedSubscribeTransport(silent: true)
        )
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        _ = try? await client.subscribePane(paneId: "P")
        await waitOutTheProbe()
        #expect(await transport.pingsSeen() == 0, "no control-peer question was raised")
        #expect(reports == 0)
    }

    @Test
    func aPaneLaneReplyDoesNotCallOffAControlProbe() async {
        // The other half of the same separation. A pane peer answering says
        // nothing about whether the control peer is, so letting it count would
        // leave a genuinely wedged control connection undiagnosed for as long
        // as frames kept arriving.
        let (client, transport) = makeClient(
            paneSubscribe: ScriptedSubscribeTransport(silent: false)
        )
        await transport.script([.silent])
        await transport.scriptPing([.silent])
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        await call(client)
        _ = try? await client.subscribePane(paneId: "P")
        await waitOutTheProbe()
        #expect(reports == 1)
    }

    @Test
    func anExpiryThatOutlivedItsConnectionDiagnosesNothing() async {
        // The call was sent to a peer that has since been replaced, so its
        // expiry only says the old one never answered, which is already known.
        // Probing on the current generation would diagnose a connection nothing
        // of ours has gone unanswered on yet.
        let (client, transport) = makeClient()
        await transport.script([.silent])
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        async let expiring: Void = call(client)
        try? await Task.sleep(nanoseconds: 5_000_000)
        client.adoptReconnectedConnection(2)
        await expiring
        await waitOutTheProbe()
        #expect(await transport.pingsSeen() == 0)
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
        await transport.script([.silent])
        await transport.scriptPing([.silent])
        await call(client)
        await waitOutTheProbe()
        #expect(named == [1], "the connection `connect()` established")
    }

    @Test
    func aCallThatSkipsTheSharedBoundStillCountsAsAReply() async {
        // The attaches and `session.create` bound themselves rather than going
        // through the shared wrapper, because cancelling them would discard
        // the reply naming what they minted. An attach answering promptly is
        // as much proof the helper is alive as any other reply, so it has to
        // call off a probe too.
        let (client, transport) = makeClient()
        await transport.script([.silent, .answers])
        await transport.scriptPing([.silent])
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        await call(client)
        _ = try? await client.attachDevice(sessionId: "S", capability: "C", udid: "U")
        await waitOutTheProbe()
        #expect(reports == 0)
    }

    @Test
    func aRefusedSelfBoundCallCountsAsAReplyToo() async {
        // The same rule on the same path: a refused attach is a reply. This is
        // the shape that made classifying failures in one place worth doing,
        // because the self-bound path and the shared bound have to agree and
        // there is nothing in the types to make them.
        let (client, transport) = makeClient()
        await transport.script([.silent, .refuses])
        await transport.scriptPing([.silent])
        var reports = 0
        client.onUnresponsive = { _ in reports += 1 }
        await call(client)
        _ = try? await client.attachDevice(sessionId: "S", capability: "C", udid: "U")
        await waitOutTheProbe()
        #expect(reports == 0)
    }
}
