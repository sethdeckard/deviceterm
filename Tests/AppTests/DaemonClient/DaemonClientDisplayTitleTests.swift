// SPDX-License-Identifier: GPL-3.0-or-later
//
// The `session.setDisplayTitle` client surface: no cap on the wire (the
// `.validatedGUI` audit token is the authority), the title bounded BEFORE
// encoding so a hostile OSC title never becomes a giant XPC payload, and a
// clear transmitted as an explicit null rather than an omitted key.

@testable import App
import DaemonProtocol
import Foundation
import Testing

@MainActor
struct DaemonClientDisplayTitleTests {
    /// Records each request's method + raw params; returns an empty object
    /// body (`setDisplayTitle` ignores the reply).
    ///
    /// `@unchecked Sendable` invariant: each test owns one instance and drives
    /// it from a single task, one awaited call at a time, inspecting `calls`
    /// only after that call completes.
    private final class RecordingTransport: DaemonRequestTransport, @unchecked Sendable {
        private(set) var calls: [(method: String, params: Data?)] = []
        func request(method: String, params: Data?) async -> Data {
            await Task.yield()
            calls.append((method, params))
            return Data("{}".utf8)
        }
    }

    @Test
    func sendsValidatedGUIShapeWithNoCapOnTheWire() async throws {
        let transport = RecordingTransport()
        let client = DaemonClient(injecting: transport)

        try await client.setDisplayTitle(sessionId: "sess-1", title: "vim foo.swift")

        let call = try #require(transport.calls.first)
        #expect(call.method == RPCMethod.sessionSetDisplayTitle.rawValue)
        let params = try #require(call.params)
        let decoded = try JSONDecoder().decode(SessionSetDisplayTitleParams.self, from: params)
        #expect(decoded.sessionId == "sess-1")
        #expect(decoded.title == "vim foo.swift")
        let object = try JSONSerialization.jsonObject(with: params) as? [String: Any]
        #expect(object?["cap"] == nil)
        #expect(object?["capability"] == nil)
    }

    @Test
    func boundsAnOversizedTitleBeforeItCrossesTheWire() async throws {
        // An OSC title is unbounded caller-controlled text. The daemon
        // normalizes too, but only AFTER receiving, so the client's pass is
        // what keeps the payload small.
        let transport = RecordingTransport()
        let client = DaemonClient(injecting: transport)

        try await client.setDisplayTitle(
            sessionId: "sess-1",
            title: String(repeating: "A", count: 2_000)
        )

        let params = try #require(transport.calls.first?.params)
        let decoded = try JSONDecoder().decode(SessionSetDisplayTitleParams.self, from: params)
        #expect(decoded.title?.utf8.count == DisplayTitleNormalizer.byteBudget)
        #expect(params.count < 512)
    }

    @Test
    func transmitsAClearRatherThanSkippingIt() async throws {
        // A title that normalizes to nothing must still replace the cached
        // one, so it goes out as an explicit null, not an omitted key a
        // decoder could read as "unchanged".
        let transport = RecordingTransport()
        let client = DaemonClient(injecting: transport)

        try await client.setDisplayTitle(sessionId: "sess-1", title: "\u{202A}\u{202C}")

        let params = try #require(transport.calls.first?.params)
        let object = try JSONSerialization.jsonObject(with: params) as? [String: Any]
        #expect(object?.keys.contains("title") == true)
        #expect(object?["title"] is NSNull)
    }
}
