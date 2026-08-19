// SPDX-License-Identifier: GPL-3.0-or-later
//
// Wire-version-mismatch remediation: on a definite mismatch the GUI issues
// `daemon.shutdown` to the incompatible daemon and awaits the ack BEFORE
// surfacing the user-facing remediation: so a Sparkle-replaced bundle can't
// leave the old helper alive to be reconnected to. Driven hermetically through
// the injected `DaemonRequestTransport`, which scripts `daemon.ping` (the
// handshake) and `daemon.shutdown`.

@testable import App
import DaemonProtocol
import Foundation
import Testing
@preconcurrency import XPC

@MainActor
struct DaemonClientVersionMismatchTests {
    /// Scripts `daemon.ping` and `daemon.shutdown`. `pingVersions` is consumed
    /// one entry per ping call: a String yields that wire version, a nil throws
    /// a transient transport error (a daemon still coming up). `shutdown`
    /// behavior is fixed per instance.
    ///
    /// `@unchecked Sendable` invariant: each test owns one instance and drives it
    /// from a single serial task (every `DaemonClient` call awaited before the
    /// next), inspecting recorded state only after those calls return, so the
    /// mutable fields are never touched concurrently.
    private final class ScriptedTransport: DaemonRequestTransport, @unchecked Sendable {
        enum ShutdownBehavior { case ack, nack, fail, hang }

        private(set) var methods: [String] = []
        private var pingVersions: [String?]
        /// Pids answered one per ping, the last one repeating once the script
        /// runs out. Recovery classifies pid before version, so a test about
        /// waiting out a stopping helper has to be able to replay the pinned pid,
        /// which recovery treats as the old helper still answering.
        private var pingPids: [Int32]
        private var lastPid: Int32 = 1
        private let shutdownBehavior: ShutdownBehavior
        var shutdownCount: Int { methods.filter { $0 == RPCMethod.daemonShutdown.rawValue }.count }
        var pingCount: Int { methods.filter { $0 == RPCMethod.daemonPing.rawValue }.count }

        init(
            pingVersions: [String?],
            pingPids: [Int32] = [],
            shutdown: ShutdownBehavior = .ack
        ) {
            self.pingVersions = pingVersions
            self.pingPids = pingPids
            self.shutdownBehavior = shutdown
        }

        private func nextPid() -> Int32 {
            if !pingPids.isEmpty { lastPid = pingPids.removeFirst() }
            return lastPid
        }

        func request(method: String, params: Data?) async throws -> Data {
            await Task.yield()
            methods.append(method)
            switch method {
            case RPCMethod.daemonPing.rawValue:
                let version = pingVersions.isEmpty ? "9.9.9" : pingVersions.removeFirst()
                guard let version else {
                    throw DaemonClientError.transport("daemon still coming up")
                }
                return try JSONEncoder().encode(
                    DaemonPingResponse(version: version, pid: nextPid())
                )

            case RPCMethod.daemonShutdown.rawValue:
                switch shutdownBehavior {
                case .ack:
                    return Data(#"{"ok":true}"#.utf8)

                case .nack:
                    return Data(#"{"ok":false}"#.utf8)

                case .fail:
                    throw DaemonClientError.transport("connection closed")

                case .hang:
                    // Answer `ping` normally but never reply to shutdown: sleep
                    // past any test timeout; the client's bound must fire first.
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return Data(#"{"ok":true}"#.utf8)
                }

            default:
                Issue.record("unexpected method \(method)")
                return Data("{}".utf8)
            }
        }
    }

    private let mismatch = DaemonClientError.versionMismatch(client: "0.2.0", daemon: "9.9.9")

    private func isConfirmed(_ outcome: VersionMismatchOutcome?) -> Bool {
        guard let outcome else { return false }
        if case .confirmed = outcome.shutdown { return true }
        return false
    }

    private func isIndeterminate(_ outcome: VersionMismatchOutcome?) -> Bool {
        guard let outcome else { return false }
        if case .indeterminate = outcome.shutdown { return true }
        return false
    }

    // MARK: - A definite mismatch attempts the shutdown RPC before surfacing

    @Test
    func mismatchAttemptsShutdownBeforeSurfacing() async {
        let transport = ScriptedTransport(pingVersions: [], shutdown: .ack)
        let client = DaemonClient(injecting: transport)
        var captured: [VersionMismatchOutcome] = []
        client.onVersionMismatch = { captured.append($0) }

        let gen = await client.currentXPCGeneration()
        await client.surfaceVersionMismatch(mismatch, generation: gen)

        // The shutdown RPC was sent, and it was sent before (not instead of)
        // surfacing: the ack makes the outcome a confirmed acceptance.
        #expect(transport.shutdownCount == 1)
        #expect(captured.count == 1)
        #expect(isConfirmed(captured.first))
    }

    // MARK: - Remediation happens at most once per client lifetime

    @Test
    func reconnectMismatchRemediatesOnce() async {
        // Two reconnect handshakes both see the mismatch (the second models the
        // shutdown's own XPC invalidation re-firing the reconnect handler). Only
        // one shutdown is sent, and the user is alerted once.
        let transport = ScriptedTransport(pingVersions: ["9.9.9", "9.9.9"], shutdown: .ack)
        let client = DaemonClient(injecting: transport)
        var alerts = 0
        client.onVersionMismatch = { _ in alerts += 1 }

        await client.runReconnectHandshake(generation: client.reconnectGeneration)
        await client.runReconnectHandshake(generation: client.reconnectGeneration)

        #expect(transport.shutdownCount == 1)
        #expect(alerts == 1)
    }

    // MARK: - Transient handshake failures retry and never shut down

    @Test
    func transientHandshakeFailuresRetryWithoutShutdown() async {
        // First ping throws (daemon still respawning), second returns the
        // MATCHING version → the handshake succeeds on retry. No shutdown, and
        // the reconnect completes (onReconnected fires).
        let transport = ScriptedTransport(
            pingVersions: [nil, DaemonProtocolInfo.wireVersion],
            shutdown: .ack
        )
        let client = DaemonClient(injecting: transport)
        var alerted = false
        var reconnected = false
        client.onVersionMismatch = { _ in alerted = true }
        client.onReconnected = { reconnected = true }

        await client.runReconnectHandshake(generation: client.reconnectGeneration)

        #expect(transport.shutdownCount == 0)
        #expect(!alerted)
        #expect(reconnected)
    }

    // MARK: - An unacknowledged shutdown is not reported as confirmed

    @Test
    func unacknowledgedShutdownIsIndeterminateNotConfirmed() async {
        // The daemon replies `{ok:false}`: no acceptance; the state is unknown.
        let nacked = ScriptedTransport(pingVersions: [], shutdown: .nack)
        let clientA = DaemonClient(injecting: nacked)
        var outcomeA: VersionMismatchOutcome?
        clientA.onVersionMismatch = { outcomeA = $0 }
        let genA = await clientA.currentXPCGeneration()
        await clientA.surfaceVersionMismatch(mismatch, generation: genA)
        #expect(isIndeterminate(outcomeA))
        #expect(!isConfirmed(outcomeA))

        // The shutdown request itself fails at the transport: the ack may have
        // raced an accepted shutdown, so it's indeterminate, never confirmed.
        let failed = ScriptedTransport(pingVersions: [], shutdown: .fail)
        let clientB = DaemonClient(injecting: failed)
        var outcomeB: VersionMismatchOutcome?
        clientB.onVersionMismatch = { outcomeB = $0 }
        let genB = await clientB.currentXPCGeneration()
        await clientB.surfaceVersionMismatch(mismatch, generation: genB)
        #expect(isIndeterminate(outcomeB))
        #expect(!isConfirmed(outcomeB))
    }

    // MARK: - A stalled shutdown times out to indeterminate, not forever

    @Test
    func shutdownWithoutReplyTimesOutToIndeterminate() async {
        // The daemon answers ping but never acks shutdown. The bound must fire
        // (small in the test) and report the outcome as indeterminate: the
        // remediation/alert can't be left hanging.
        let transport = ScriptedTransport(pingVersions: [], shutdown: .hang)
        let client = DaemonClient(injecting: transport)
        client.shutdownAckTimeoutNanos = 50_000_000  // 50ms
        var outcome: VersionMismatchOutcome?
        client.onVersionMismatch = { outcome = $0 }

        let gen = await client.currentXPCGeneration()
        await client.surfaceVersionMismatch(mismatch, generation: gen)

        #expect(isIndeterminate(outcome))
        #expect(!isConfirmed(outcome))
    }

    // MARK: - Shutdown is pinned to the mismatched daemon instance (generation)

    /// Exercises the ATOMIC ping-generation capture end to end over a controlled
    /// XPC peer: the peer answers `daemon.ping` with a mismatched version but
    /// holds the reply while the test bumps the connection generation (models a
    /// replacement connecting during the round-trip). Because the generation was
    /// stamped at SEND (not sampled after the reply), remediation sees the OLD
    /// generation, the fence rejects, and NO `daemon.shutdown` is sent to the
    /// replacement. Sampling the generation after the reply would target a
    /// replacement; the send-time stamp fences shutdown to the daemon that
    /// answered.
    @Test
    func atomicPingGenerationPreventsShutdownOfReplacementPeer() async {
        let peer = GatedReplyPeer(replyVersion: "9.9.9")  // mismatched wire version
        peer.start()
        defer { peer.stop() }
        let client = DaemonClient()  // production init → XPC transport
        await client.xpcConnectionForTesting().connectWithTestPeer(peer.clientPeer)
        var outcome: VersionMismatchOutcome?
        client.onVersionMismatch = { outcome = $0 }

        // Drive the handshake; the ping is answered by the gated peer.
        let task = Task { try? await client.versionHandshake() }
        // Wait until the peer has received the ping (request in flight, so the
        // generation is already stamped at send).
        let received = await poll { peer.receivedPing }
        #expect(received)
        // Replace the connection (bump generation) BEFORE the reply is processed
        // (the window where a post-ping sample would capture the wrong value).
        await client.xpcConnectionForTesting().bumpGenerationForTesting()
        peer.release()  // let the mismatched-version reply flow
        _ = await task.value

        // The stamped OLD generation prevents shutting down the replacement.
        #expect(isIndeterminate(outcome))
        #expect(!peer.receivedMethods.contains(RPCMethod.daemonShutdown.rawValue))
    }

    private func poll(_ timeout: Double = 2.0, _ cond: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await cond()
    }

    @Test
    func remediationRejectedWhenConnectionReplacedSincePing() async {
        // The connection was replaced (a demand-reconnect bumped the generation)
        // between the mismatched ping and the fence: the incompatible instance
        // is gone. No shutdown is sent to the current (different) daemon, and the
        // outcome is indeterminate ("replaced"), never a shutdown of the wrong
        // instance.
        let transport = ScriptedTransport(pingVersions: [], shutdown: .ack)
        let client = DaemonClient(injecting: transport)
        var outcome: VersionMismatchOutcome?
        client.onVersionMismatch = { outcome = $0 }

        // Ping was answered on the current generation; passing a DIFFERENT
        // (stale) one models a replacement occurring before the fence.
        let stale = await client.currentXPCGeneration() + 1
        await client.surfaceVersionMismatch(mismatch, generation: stale)

        #expect(transport.shutdownCount == 0)  // never shut down the replacement
        #expect(isIndeterminate(outcome))
    }

    // MARK: - A handled mismatch never restores against a re-launched daemon

    @Test
    func handledMismatchSuppressesLaterMatchingReconnect() async {
        // Model the shutdown's own XPC invalidation re-firing the reconnect
        // handler onto a freshly demand-launched UPDATED daemon whose handshake
        // now MATCHES. Restoration must not run: the app is quitting.
        let transport = ScriptedTransport(
            pingVersions: [DaemonProtocolInfo.wireVersion],
            shutdown: .ack
        )
        let client = DaemonClient(injecting: transport)
        var reconnected = false
        client.onVersionMismatch = { _ in }
        client.onReconnected = { reconnected = true }

        // Handle a definite mismatch (latches, sends the shutdown), then the
        // reconnect fires with a matching daemon.
        let gen = await client.currentXPCGeneration()
        await client.surfaceVersionMismatch(mismatch, generation: gen)
        await client.runReconnectHandshake(generation: client.reconnectGeneration)

        #expect(!reconnected)  // no restore against the replacement daemon
    }

    // MARK: - Startup recovery: detection fences without reporting

    @Test
    func startupMismatchFencesAndThrowsWithoutSurfacing() async {
        // The startup path owns its own ladder, so detection must not spend the
        // shutdown or put anything on screen: `onVersionMismatch` stays the
        // mid-session vocabulary.
        let transport = ScriptedTransport(pingVersions: ["9.9.9"], shutdown: .ack)
        let client = DaemonClient(injecting: transport)
        var surfaced = 0
        client.onVersionMismatch = { _ in surfaced += 1 }

        do {
            try await client.startupVersionHandshake()
            Issue.record("expected the startup handshake to throw the mismatch")
        } catch let error as DaemonClientError {
            #expect(error.isVersionMismatch)
        } catch {
            Issue.record("expected a DaemonClientError, got \(error)")
        }

        #expect(surfaced == 0)
        #expect(transport.shutdownCount == 0)
    }

    // MARK: - The recovery verdict reads pid before version

    @Test
    func recoveryHandshakeReadsTheSamePidAsNotYetReplaced() async {
        // The grace-period regression guard. `daemon.shutdown` acks before the
        // daemon exits, so on the SUCCESSFUL path the old helper may answer
        // again with the old version. Reading that as a verdict would surrender on the
        // happy path.
        let transport = ScriptedTransport(pingVersions: ["9.9.9", "9.9.9"], pingPids: [7, 7])
        let client = DaemonClient(injecting: transport)

        try? await client.startupVersionHandshake()
        let outcome = await client.recoveryHandshake()

        #expect(outcome == .sameHelperStillAnswering(pid: 7))
    }

    @Test
    func recoveryHandshakeReportsCompatibleOnANewPid() async {
        let transport = ScriptedTransport(
            pingVersions: ["9.9.9", DaemonProtocolInfo.wireVersion],
            pingPids: [7, 8]
        )
        let client = DaemonClient(injecting: transport)

        try? await client.startupVersionHandshake()

        #expect(await client.recoveryHandshake() == .compatible)
    }

    @Test
    func recoveryHandshakeReportsIncompatibleOnANewPid() async {
        // A different process answering with a different version is decisive:
        // the registration resolves to a helper that does not match this build,
        // and stopping it again would not converge.
        let transport = ScriptedTransport(pingVersions: ["9.9.9", "8.8.8"], pingPids: [7, 8])
        let client = DaemonClient(injecting: transport)

        try? await client.startupVersionHandshake()

        #expect(await client.recoveryHandshake() == .incompatible(daemonVersion: "8.8.8", pid: 8))
    }

    @Test
    func recoveryHandshakeReportsUnreachableWhenNothingAnswers() async {
        let transport = ScriptedTransport(pingVersions: ["9.9.9", nil], pingPids: [7])
        let client = DaemonClient(injecting: transport)

        try? await client.startupVersionHandshake()

        guard case .unreachable = await client.recoveryHandshake() else {
            Issue.record("expected unreachable when the ping throws")
            return
        }
    }

    // MARK: - Recovery owns the version flow while it runs

    @Test
    func reconnectHandshakeStandsDownDuringRecovery() async {
        // The shutdown invalidates the connection, which re-fires the reconnect
        // handler. It must not handshake, restore, or demand-launch while the
        // ladder is working the same transport.
        let transport = ScriptedTransport(pingVersions: ["9.9.9"], shutdown: .ack)
        let client = DaemonClient(injecting: transport)
        var reconnected = false
        client.onReconnected = { reconnected = true }

        try? await client.startupVersionHandshake()
        let pingsAfterDetection = transport.pingCount
        await client.runReconnectHandshake(generation: client.reconnectGeneration)

        #expect(!reconnected)
        #expect(transport.pingCount == pingsAfterDetection)  // never handshaked
        #expect(transport.shutdownCount == 0)
    }

    @Test
    func recoveryPingsDoNotRaiseTheUnresponsiveSignal() async {
        // The ladder deliberately pings a helper it just asked to stop, several
        // times. Those expiries reach the unresponsive threshold easily, and the
        // prompt they would raise both interrupts a silent launch and races the
        // ladder for the same helper.
        let transport = ScriptedTransport(pingVersions: ["9.9.9", nil, nil, nil, nil])
        let client = DaemonClient(injecting: transport)
        var unresponsive = 0
        client.onUnresponsive = { _ in unresponsive += 1 }

        try? await client.startupVersionHandshake()
        for _ in 0..<4 {
            _ = await client.recoveryHandshake()
        }

        #expect(unresponsive == 0)
    }

    // MARK: - Leaving and abandoning recovery

    @Test
    func successfulRecoveryLeavesTheMismatchLatchClear() async {
        // Recovery is not a surrender: a later mid-session mismatch on the same
        // client must still be able to report.
        let transport = ScriptedTransport(pingVersions: ["9.9.9"], shutdown: .ack)
        let client = DaemonClient(injecting: transport)
        var surfaced = 0
        client.onVersionMismatch = { _ in surfaced += 1 }

        try? await client.startupVersionHandshake()
        await client.leaveVersionRecovery()

        let gen = await client.currentXPCGeneration()
        await client.surfaceVersionMismatch(mismatch, generation: gen)

        #expect(surfaced == 1)
    }

    @Test
    func abandonedRecoverySuppressesALaterMidSessionSurface() async {
        // Abandoning IS the surrender, and the caller reports it with more
        // detail than the mid-session path has, so a second report would be a
        // duplicate.
        let transport = ScriptedTransport(pingVersions: ["9.9.9"], shutdown: .ack)
        let client = DaemonClient(injecting: transport)
        var surfaced = 0
        client.onVersionMismatch = { _ in surfaced += 1 }

        try? await client.startupVersionHandshake()
        await client.abandonVersionRecovery()

        let gen = await client.currentXPCGeneration()
        await client.surfaceVersionMismatch(mismatch, generation: gen)

        #expect(surfaced == 0)
    }
}

/// A controlled XPC peer that answers `daemon.ping` with a chosen wire version,
/// but HOLDS the reply until `release()`: so a test can change state (bump the
/// connection generation) between the request being received and the reply
/// being processed. Records every method it receives so a test can assert no
/// `daemon.shutdown` was sent.
///
/// `@unchecked Sendable` invariant: `storedMethods` is serialized under
/// `lock`; the reply gate is a thread-safe semaphore; the XPC handles are
/// thread-safe. The peer handler runs on libxpc's queue, distinct from the
/// test's actor.
private final class GatedReplyPeer: @unchecked Sendable {
    let clientPeer: xpc_connection_t
    private let listener: xpc_connection_t
    private let replyVersion: String
    private let lock = NSLock()
    private var storedMethods: [String] = []
    private let gate = DispatchSemaphore(value: 0)

    var receivedMethods: [String] { lock.lock(); defer { lock.unlock() }; return storedMethods }
    var receivedPing: Bool { receivedMethods.contains(RPCMethod.daemonPing.rawValue) }

    init(replyVersion: String) {
        self.replyVersion = replyVersion
        let listener = xpc_connection_create(nil, nil)
        self.listener = listener
        let endpoint = xpc_endpoint_create(listener)
        // Unresumed: `connectWithTestPeer`/`installPeer` wires + resumes it.
        self.clientPeer = xpc_connection_create_from_endpoint(endpoint)
    }

    func start() {
        xpc_connection_set_event_handler(listener) { [weak self] event in
            guard let self, xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
            let incoming = event
            xpc_connection_set_event_handler(incoming) { [weak self] message in
                self?.handleIncoming(message, on: incoming)
            }
            xpc_connection_resume(incoming)
        }
        xpc_connection_resume(listener)
    }

    func release() { gate.signal() }

    func stop() {
        xpc_connection_cancel(clientPeer)
        xpc_connection_cancel(listener)
    }

    private func handleIncoming(_ message: xpc_object_t, on peer: xpc_connection_t) {
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return }
        var length = 0
        guard let pointer = xpc_dictionary_get_data(message, XPCWireKey.data, &length), length > 0,
            let envelope = try? RPCEnvelope.decode(Data(bytes: pointer, count: length)),
            let requestId = envelope.id,
            let method = envelope.method
        else { return }
        lock.lock(); storedMethods.append(method); lock.unlock()
        // Only the ping is answered (gated); a stray shutdown is recorded but
        // never replied to: its presence alone fails the test.
        guard method == RPCMethod.daemonPing.rawValue else { return }
        gate.wait()  // held until the test releases
        let pong = DaemonPingResponse(version: replyVersion, pid: 1)
        guard let pongData = try? JSONEncoder().encode(pong) else { return }
        let response = RPCEnvelope(id: requestId, type: .response, method: nil, body: .result(pongData))
        guard let responseData = try? response.encode() else { return }
        let reply = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(reply, XPCWireKey.type, XPCWireKey.rpcValue)
        responseData.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            xpc_dictionary_set_data(reply, XPCWireKey.data, base, responseData.count)
        }
        xpc_connection_send_message(peer, reply)
    }
}
