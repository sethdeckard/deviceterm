// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reconnect re-authentication regression tests (one-shot requests and
// pane subscriptions).
//
// When the daemon idle-exits/respawns (or an XPC connection is
// interrupted), its fresh `RPCConnection` is unauthenticated, so the
// GUI's next session-scoped call fails with -32001 ("session-scoped
// method requires an authenticated connection") even though a valid
// session exists. Both `DaemonClient.request` and `subscribePane` catch
// that one code, re-send `session.authenticate` with a live-session
// credential, and retry the call once. These tests pin that behavior (and
// that closing the newest session doesn't strand the reauth credential)
// via injected scripted transports (`DaemonRequestTransport` /
// `DaemonSubscribeTransport`).

@testable import App
import DaemonProtocol
import Foundation
import Testing

@MainActor
struct DaemonClientReauthTests {
    /// A scripted `request` transport: records every call in order and
    /// returns canned JSON per method. `device.list` fails with -32001
    /// on its first call and succeeds on the second, simulating a
    /// reconnect that drops the connection's authentication.
    ///
    /// `@unchecked Sendable` invariant: each test owns one instance, drives
    /// it from a single task (one `DaemonClient` call at a time, each awaited
    /// before the next), and inspects the recorded state only after those
    /// awaited calls complete. So the mutable fields are never accessed
    /// concurrently: no cross-task sharing, no overlapping invocations.
    private final class ScriptedRequestTransport: DaemonRequestTransport,
        @unchecked Sendable {
        private(set) var methods: [String] = []
        /// Each session.authenticate *attempt*'s decoded sessionId, in call
        /// order (recorded even when the daemon then rejects it).
        private(set) var authenticatedSessionIds: [String] = []
        /// When true, the next `device.list` returns -32001 once.
        var failNextDeviceList = true
        /// Sessions the daemon has deleted: `session.authenticate` for these
        /// -32001s (the session is gone), modeling a lost-close-response.
        var deadSessionIds: Set<String> = []
        /// When true, the next `session.close` throws a transport error. To
        /// model the daemon deleting the session despite a lost close
        /// response, a test sets this **and** adds the session to
        /// `deadSessionIds` (this flag alone only drops the response).
        var failNextSessionClose = false
        /// When true, the next `session.authenticate` throws a transport
        /// error (the connection dropped mid-reauth).
        var failNextAuthenticateWithTransport = false
        private var createdCount = 0

        func request(method: String, params: Data?) async throws -> Data {
            await Task.yield()
            methods.append(method)
            switch method {
            case RPCMethod.sessionCreate.rawValue:
                createdCount += 1
                return try JSONEncoder().encode(
                    SessionCreateResponse(
                        sessionId: "sess-\(createdCount)",
                        capability: "cap"
                    )
                )

            case RPCMethod.sessionAuthenticate.rawValue:
                if failNextAuthenticateWithTransport {
                    failNextAuthenticateWithTransport = false
                    throw DaemonClientError.transport("connection closed")
                }
                if let params,
                    let auth = try? JSONDecoder().decode(
                        SessionAuthenticateParams.self,
                        from: params
                    ) {
                    authenticatedSessionIds.append(auth.sessionId)
                    if deadSessionIds.contains(auth.sessionId) {
                        throw DaemonClientError.daemon(
                            code: -32_001,
                            message: "invalid sessionId or cap"
                        )
                    }
                }
                return try JSONEncoder().encode(
                    SessionAuthenticateResponse(success: true, role: .agent)
                )

            case RPCMethod.sessionClose.rawValue:
                if failNextSessionClose {
                    failNextSessionClose = false
                    throw DaemonClientError.transport("connection closed")
                }
                return Data("{}".utf8)

            case RPCMethod.daemonCapabilities.rawValue:
                return try JSONEncoder().encode(
                    DaemonCapabilitiesResponse(
                        role: .agent,
                        allowedMethods: [],
                        wireVersion: DaemonProtocolInfo.wireVersion,
                        linkagePolicyVersion: LinkagePolicy.currentVersion
                    )
                )

            case RPCMethod.deviceList.rawValue:
                if failNextDeviceList {
                    failNextDeviceList = false
                    throw DaemonClientError.daemon(
                        code: -32_001,
                        message: "session-scoped method requires an "
                            + "authenticated connection; call "
                            + "session.authenticate first"
                    )
                }
                return try JSONEncoder().encode([DeviceListEntry]())

            case RPCMethod.sessionSetProtectedBatch.rawValue,
                RPCMethod.sessionSetCohort.rawValue:
                // Always -32001 (unknown session named), the case the
                // reauth-exclusion tests exercise.
                throw DaemonClientError.daemon(
                    code: -32_001,
                    message: "unknown session in batch"
                )

            default:
                return Data("{}".utf8)
            }
        }
    }

    /// A transport that fails *every* `device.list` with -32001.
    ///
    /// `@unchecked Sendable` invariant: same as `ScriptedRequestTransport`:
    /// the client issues calls sequentially and reads state only after the
    /// awaits resolve, so `methods` is never accessed concurrently.
    private final class AlwaysUnauthorizedTransport: DaemonRequestTransport,
        @unchecked Sendable {
        private(set) var methods: [String] = []

        func request(method: String, params: Data?) async throws -> Data {
            await Task.yield()
            methods.append(method)
            throw DaemonClientError.daemon(code: -32_001, message: "unauthorized")
        }
    }

    /// A scripted subscribe transport: -32001s the first `subscribePane`
    /// (a reconnect dropped the connection's authentication) and returns a
    /// finished stream on the retry.
    ///
    /// `@unchecked Sendable` invariant: same as `ScriptedRequestTransport`:
    /// the client issues calls sequentially and reads state only after the
    /// awaits resolve, so `attempts`/`failNext` are never accessed
    /// concurrently.
    private final class ScriptedSubscribeTransport: DaemonSubscribeTransport,
        @unchecked Sendable {
        private(set) var attempts = 0
        var failNext = true

        func subscribePane(paneId: String) async throws -> AsyncStream<PaneEvent> {
            await Task.yield()
            attempts += 1
            if failNext {
                failNext = false
                throw DaemonClientError.daemon(
                    code: -32_001,
                    message: "session-scoped method requires an "
                        + "authenticated connection"
                )
            }
            return AsyncStream { $0.finish() }
        }
    }

    @Test
    func reauthenticatesAndRetriesAfterUnauthorized() async throws {
        let transport = ScriptedRequestTransport()
        let client = DaemonClient(injecting: transport)
        // Seeds the live-session credential (records one session.authenticate).
        _ = try await client.createSession(label: nil, name: nil, role: .agent)

        // First device.list -32001s; the client re-auths and retries,
        // so the call succeeds despite the failure.
        let devices = try await client.deviceList(scope: .owned)
        #expect(devices.isEmpty)

        // device.list was attempted twice (fail, then retry), in order.
        #expect(transport.methods.filter { $0 == RPCMethod.deviceList.rawValue }
            .count == 2)
        // session.authenticate was sent twice: once in createSession,
        // once in the retry.
        #expect(transport.methods.filter {
            $0 == RPCMethod.sessionAuthenticate.rawValue
        }.count == 2)
        // The retry re-auth happened *before* the second device.list.
        let lastAuth = transport.methods.lastIndex(
            of: RPCMethod.sessionAuthenticate.rawValue
        )
        let lastList = transport.methods.lastIndex(
            of: RPCMethod.deviceList.rawValue
        )
        if let lastAuth, let lastList {
            #expect(lastAuth < lastList)
        } else {
            Issue.record("expected both session.authenticate and device.list")
        }
    }

    @Test
    func setProtectedBatchUnauthorizedIsNotTransparentlyRetried() async throws {
        // `session.setProtectedBatch` must be EXCLUDED from the reconnect
        // reauth retry: its -32001 means "unknown session" (never a lost
        // connection, it's `.validatedGUI`, not session-authed), and a
        // transparent retry would resend the SAME encoded `revision`,
        // violating fresh-revision-per-send. The -32001 must propagate so
        // the Router owns any retry (with a fresh revision).
        let transport = ScriptedRequestTransport()
        let client = DaemonClient(injecting: transport)
        _ = try await client.createSession(label: nil, name: nil, role: .agent)
        let authBefore = transport.methods.filter {
            $0 == RPCMethod.sessionAuthenticate.rawValue
        }.count
        await #expect(throws: DaemonClientError.self) {
            _ = try await client.setProtectedBatch(
                sessionIds: ["S"], isProtected: true, revision: 7
            )
        }
        // Sent exactly once: no transparent retry.
        #expect(transport.methods.filter {
            $0 == RPCMethod.sessionSetProtectedBatch.rawValue
        }.count == 1)
        // No extra session.authenticate for a retry.
        #expect(transport.methods.filter {
            $0 == RPCMethod.sessionAuthenticate.rawValue
        }.count == authBefore)
    }

    @Test
    func setCohortUnauthorizedIsNotTransparentlyRetried() async throws {
        // `session.setCohort` shares `setProtectedBatch`'s exclusion: it is
        // `.validatedGUI` (no session auth to lose on reconnect) and carries
        // a fresh-per-send `revision`, so a transparent retry would replay a
        // stale key. The -32001 must propagate so the Router owns any retry.
        let transport = ScriptedRequestTransport()
        let client = DaemonClient(injecting: transport)
        _ = try await client.createSession(label: nil, name: nil, role: .agent)
        let authBefore = transport.methods.filter {
            $0 == RPCMethod.sessionAuthenticate.rawValue
        }.count
        await #expect(throws: DaemonClientError.self) {
            _ = try await client.setCohort(
                SessionSetCohortParams(
                    operation: .reconcile,
                    cohortId: UUID().uuidString,
                    revision: 7,
                    members: ["S"],
                    representative: "S"
                )
            )
        }
        // Sent exactly once: no transparent retry.
        #expect(transport.methods.filter {
            $0 == RPCMethod.sessionSetCohort.rawValue
        }.count == 1)
        // No extra session.authenticate for a retry.
        #expect(transport.methods.filter {
            $0 == RPCMethod.sessionAuthenticate.rawValue
        }.count == authBefore)
    }

    @Test
    func reauthenticatesAndRetriesSubscribeAfterUnauthorized() async throws {
        let request = ScriptedRequestTransport()
        let subscribe = ScriptedSubscribeTransport()
        let client = DaemonClient(injecting: request, subscribe: subscribe)
        // Seeds the live-session credential.
        _ = try await client.createSession(label: nil, name: nil, role: .agent)

        // First subscribe -32001s; the client re-auths and retries, so the
        // call returns a stream rather than throwing.
        _ = try await client.subscribePane(paneId: "pane")

        // subscribePane was attempted twice (fail, then retry).
        #expect(subscribe.attempts == 2)
        // A second session.authenticate was sent for the retry (the first
        // was in createSession).
        #expect(request.methods.filter {
            $0 == RPCMethod.sessionAuthenticate.rawValue
        }.count == 2)
    }

    @Test
    func rethrowsSubscribeUnauthorizedWhenNoSessionToReplay() async throws {
        // No createSession → no live-session credential, so the -32001 has
        // nothing to replay and must surface unchanged.
        let subscribe = ScriptedSubscribeTransport()
        let client = DaemonClient(
            injecting: ScriptedRequestTransport(),
            subscribe: subscribe
        )

        await #expect(throws: DaemonClientError.self) {
            _ = try await client.subscribePane(paneId: "pane")
        }
        // Only one attempt: no reauth, no retry.
        #expect(subscribe.attempts == 1)
    }

    @Test
    func reauthReplaysASurvivingSessionAfterTheNewestCloses() async throws {
        let transport = ScriptedRequestTransport()
        let client = DaemonClient(injecting: transport)
        let first = try await client.createSession(label: nil, name: nil, role: .agent)
        let second = try await client.createSession(label: nil, name: nil, role: .agent)
        // Close the most-recently authenticated session; a reconnect must
        // reauth with the surviving first session.
        try await client.closeSession(
            sessionId: second.sessionId,
            capability: second.capability
        )

        // A -32001 now reauths; it must replay the surviving first session,
        // never the deleted second one.
        _ = try await client.deviceList(scope: .owned)
        #expect(transport.authenticatedSessionIds.last == first.sessionId)
        #expect(!transport.authenticatedSessionIds.dropFirst(2)
            .contains(second.sessionId))
    }

    @Test
    func reauthPrunesADeadCredentialAndFallsBackToASurvivor() async throws {
        let transport = ScriptedRequestTransport()
        let client = DaemonClient(injecting: transport)
        let first = try await client.createSession(label: nil, name: nil, role: .agent)
        let second = try await client.createSession(label: nil, name: nil, role: .agent)

        // The daemon deleted the second session, but its close response was
        // lost (the close throws), so the client can't prune the credential
        // on the close path. It remains the preferred (newest) credential.
        transport.deadSessionIds = [second.sessionId]
        transport.failNextSessionClose = true
        await #expect(throws: DaemonClientError.self) {
            try await client.closeSession(
                sessionId: second.sessionId,
                capability: second.capability
            )
        }

        // A -32001 now reauths: it tries the dead second credential first,
        // the daemon rejects it, and reauth prunes it and falls back to the
        // surviving first credential, so the call ultimately succeeds.
        _ = try await client.deviceList(scope: .owned)
        // The dead credential was attempted then the survivor authenticated.
        #expect(transport.authenticatedSessionIds.suffix(2)
            == [second.sessionId, first.sessionId])
    }

    @Test
    func reauthPropagatesTransportFailureInsteadOfMaskingIt() async throws {
        let transport = ScriptedRequestTransport()
        let client = DaemonClient(injecting: transport)
        _ = try await client.createSession(label: nil, name: nil, role: .agent)

        // The reconnect's reauth `session.authenticate` drops the connection.
        // The transport error must propagate (not be masked as the original
        // -32001) so the caller (the pane's reconnect loop) can classify it
        // as retryable rather than terminal.
        transport.failNextAuthenticateWithTransport = true
        do {
            _ = try await client.deviceList(scope: .owned)
            Issue.record("expected a thrown error")
        } catch let DaemonClientError.daemon(code, _) {
            Issue.record("transport drop masked as daemon error \(code)")
        } catch DaemonClientError.transport {
            // Expected: the real transport error surfaced.
        }
    }

    @Test
    func rethrowsUnauthorizedWhenNoSessionToReplay() async throws {
        // No createSession → no live-session credential, so the -32001
        // has nothing to replay and must surface unchanged (no loop,
        // no spurious session.authenticate).
        let transport = AlwaysUnauthorizedTransport()
        let client = DaemonClient(injecting: transport)

        await #expect(throws: DaemonClientError.self) {
            _ = try await client.deviceList(scope: .owned)
        }
        #expect(transport.methods == [RPCMethod.deviceList.rawValue])
        #expect(!transport.methods.contains(RPCMethod.sessionAuthenticate.rawValue))
    }
}
