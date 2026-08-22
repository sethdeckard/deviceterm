// SPDX-License-Identifier: GPL-3.0-or-later
//
// The `session.restoreBatch` client surface: the request encodes the whole
// inventory under the right method, carrying each entry's existing bearer cap
// (which the daemon re-derives the verifier from, unlike a `.validatedGUI`
// method that must NOT leak a cap, restore legitimately sends it), and the
// reply decodes.

@testable import App
import DaemonProtocol
import Foundation
import Testing

@MainActor
struct DaemonClientRestoreBatchTests {
    /// Records the request and returns a valid `SessionRestoreBatchResult` so
    /// the client's decode succeeds.
    ///
    /// `@unchecked Sendable` invariant: each test owns one instance and drives
    /// it from a single task, one awaited `restoreBatch` at a time, inspecting
    /// `calls` only after the call completes, so `calls` is never accessed
    /// concurrently.
    private final class RecordingTransport: DaemonRequestTransport, @unchecked Sendable {
        private(set) var calls: [(method: String, params: Data?)] = []
        var reply = Data()
        func request(method: String, params: Data?) async -> Data {
            await Task.yield()
            calls.append((method, params))
            return reply
        }
    }

    @Test
    func restoreBatchEncodesInventoryUnderTheRestoreMethod() async throws {
        let transport = RecordingTransport()
        let sessions = [
            RestoredSession(
                sessionId: "S1",
                capability: "cap-1",
                shortId: "aaa111",
                role: .agent,
                name: "one",
                isPrivate: false
            ),
            RestoredSession(
                sessionId: "S2",
                capability: "cap-2",
                shortId: "bbb222",
                role: .automation,
                name: nil,
                isPrivate: true
            )
        ]
        transport.reply = try JSONEncoder().encode(
            SessionRestoreBatchResult(restoredCount: 2, sessionIds: ["S1", "S2"])
        )
        let client = DaemonClient(injecting: transport)

        let result = try await client.restoreBatch(sessions: sessions)

        #expect(result.restoredCount == 2)
        #expect(transport.calls.count == 1)
        let call = try #require(transport.calls.first)
        #expect(call.method == RPCMethod.sessionRestoreBatch.rawValue)
        let params = try #require(call.params)
        let decoded = try JSONDecoder().decode(SessionRestoreBatchParams.self, from: params)
        #expect(decoded.sessions == sessions)
        // The bearer cap rides inside each entry by design (the daemon
        // re-derives the verifier from it).
        #expect(decoded.sessions[0].capability == "cap-1")
    }
}
