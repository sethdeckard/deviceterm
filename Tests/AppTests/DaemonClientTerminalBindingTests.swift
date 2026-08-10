// SPDX-License-Identifier: GPL-3.0-or-later
//
// Terminal-provenance client surface: the `session.bindTerminal` request shape
// (no cap on the wire: the `.validatedGUI` audit token is the authority) and
// the reconnect-observer registry that drives a tab's rebind-on-reconnect and
// its teardown observer removal.
//
// These are the production mechanisms `TabContentViewController` relies on:
//   - init registers a reconnect observer whose closure calls
//     `rebindAllTerminals`;
//   - teardown removes exactly that observer so the registry doesn't retain a
//     dead closure across tab open/close cycles.
// The registry (add / fire / remove) is tested here against the REAL
// `DaemonClient`. The VC's own poll+bind loop reads a libghostty
// `GhosttyTerminalSurface` for a FRESH identity each attempt, so initial
// binding and fresh-identity retry stay in the GUI-smoke layer (they need a
// live graphics surface); this file covers everything below that surface.

@testable import App
import DaemonProtocol
import Foundation
import Testing

@MainActor
struct DaemonClientTerminalBindingTests {
    /// Records each request's method + raw params; returns an empty object body
    /// (`bindTerminal` ignores the reply).
    ///
    /// `@unchecked Sendable` invariant: each test owns one instance and drives it
    /// from a single task, one awaited `bindTerminal` call at a time, inspecting
    /// `calls` only after that call completes. So `calls` is never accessed
    /// concurrently: no cross-task sharing, no overlapping invocations.
    private final class RecordingTransport: DaemonRequestTransport, @unchecked Sendable {
        private(set) var calls: [(method: String, params: Data?)] = []
        func request(method: String, params: Data?) async -> Data {
            await Task.yield()  // mirror a real round-trip's await boundary
            calls.append((method, params))
            return Data("{}".utf8)
        }
    }

    /// A main-actor mutation sink so a reconnect observer closure has something
    /// to record without cross-task sharing.
    private final class Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    @Test
    func bindTerminalSendsValidatedGUIShapeWithNoCapOnTheWire() async throws {
        let transport = RecordingTransport()
        let client = DaemonClient(injecting: transport)

        try await client.bindTerminal(
            sessionId: "sess-1",
            foregroundPid: 4_242,
            ttyName: "/dev/ttys003"
        )

        #expect(transport.calls.count == 1)
        let call = try #require(transport.calls.first)
        #expect(call.method == RPCMethod.sessionBindTerminal.rawValue)
        let params = try #require(call.params)
        let decoded = try JSONDecoder().decode(SessionBindTerminalParams.self, from: params)
        #expect(decoded.sessionId == "sess-1")
        #expect(decoded.foregroundPid == 4_242)
        #expect(decoded.ttyName == "/dev/ttys003")
        // No capability rides on the wire: the audit token is the authority.
        // Assert the raw JSON has no cred key, so a future field addition that
        // leaks a cap into this `.validatedGUI` method is caught here.
        let object = try JSONSerialization.jsonObject(with: params) as? [String: Any]
        #expect(object?["cap"] == nil)
        #expect(object?["capability"] == nil)
    }

    @Test
    func reconnectObserverFiresRegisteredHandlersUntilRemoved() {
        let client = DaemonClient(injecting: RecordingTransport())
        // Two tabs register. A reconnect must fan out to both (each tab's
        // `rebindAllTerminals`), and the tokens must be distinct so one tab's
        // teardown can't remove another's observer.
        let tabA = Counter()
        let tabB = Counter()
        let tokenA = client.addReconnectObserver { tabA.bump() }
        let tokenB = client.addReconnectObserver { tabB.bump() }
        #expect(tokenA != tokenB)

        client.notifyReconnect()
        #expect(tabA.value == 1)
        #expect(tabB.value == 1)

        // Tab A tears down: removing its token stops ONLY its observer.
        client.removeReconnectObserver(tokenA)
        client.notifyReconnect()
        #expect(tabA.value == 1)  // no longer fired
        #expect(tabB.value == 2)  // still fired

        // Tab B tears down: the registry is now empty, so a reconnect is a
        // no-op (no retained dead closures across open/close cycles).
        client.removeReconnectObserver(tokenB)
        client.notifyReconnect()
        #expect(tabB.value == 2)
    }

    @Test
    func removingAnObserverTwiceIsHarmless() {
        // teardown() clears its token and `isolated deinit` guards on nil, but a
        // double-remove of the same token must still be a safe no-op.
        let client = DaemonClient(injecting: RecordingTransport())
        let tab = Counter()
        let token = client.addReconnectObserver { tab.bump() }
        client.removeReconnectObserver(token)
        client.removeReconnectObserver(token)  // idempotent
        client.notifyReconnect()
        #expect(tab.value == 0)
    }
}
