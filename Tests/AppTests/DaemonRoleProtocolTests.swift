// SPDX-License-Identifier: GPL-3.0-or-later
//
// Daemon-client role protocols + injection. Asserts that both the
// real `DaemonClient` and the test `FakeDaemonClient` satisfy every
// role, that a consumer can depend on a *single* narrow role, and that
// the fake records calls / scripts results / feeds the subscribe stream.

@testable import App
import DaemonProtocol
import Testing

@MainActor
struct DaemonRoleProtocolTests {
    // Role-typed sinks: each compiles only if the argument conforms to
    // exactly that role. Standing in for the real consumers (e.g.
    // `SimResurrect` needs only `DeviceControlling`).
    private func needsSession(_ client: any SessionControlling) {}
    private func needsDevice(_ client: any DeviceControlling) {}
    private func needsPane(_ client: any PaneControlling) {}
    private func needsSubscribe(_ client: any PaneSubscribing) {}
    private func needsAll(_ client: any DaemonClienting) {}

    @Test
    func fakeSatisfiesEveryRole() {
        let fake = FakeDaemonClient()
        needsSession(fake)
        needsDevice(fake)
        needsPane(fake)
        needsSubscribe(fake)
        needsAll(fake)
    }

    @Test
    func daemonClientSatisfiesEveryRole() {
        // Constructing `DaemonClient` does not touch the socket; this is
        // a compile-time conformance assertion exercised at runtime.
        let client = DaemonClient()
        needsSession(client)
        needsDevice(client)
        needsPane(client)
        needsSubscribe(client)
        needsAll(client)
    }

    @Test
    func narrowConsumerUsesSingleRole() async throws {
        let fake = FakeDaemonClient()
        fake.deviceListResult = [
            DeviceListEntry(
                udid: "U",
                name: "iPhone",
                state: "Booted",
                ownedBySession: nil
            )
        ]
        // A `DeviceControlling`-only consumer drives the fake.
        let client: any DeviceControlling = fake
        _ = try await client.deviceList(scope: .owned)
        #expect(fake.deviceListCalls == [.init(scope: .owned)])
    }

    @Test
    func recordsCallsAndReturnsScriptedResults() async {
        let fake = FakeDaemonClient()
        fake.sessionToReturn = SessionCreateResponse(
            sessionId: "sess",
            capability: "cap"
        )
        let session = await fake.createSession(
            label: "x",
            name: "n",
            role: .agent,
            initialProtected: false
        )
        #expect(session.sessionId == "sess")
        #expect(
            fake.createSessionCalls == [
            .init(label: "x", name: "n", role: .agent, initialProtected: false)
            ]
            )

        await fake.closePane(paneId: "p1", mode: .shutdown, expecting: nil)
        #expect(fake.closePaneCalls == [.init(paneId: "p1", mode: .shutdown)])

        fake.paneInputTap(paneId: "p1", x: 0.5, y: 0.5)
        #expect(fake.paneInputCalls.map(\.method) == [.paneInputTap])
        #expect(fake.paneInputCalls.map(\.paneId) == ["p1"])
    }

    @Test
    func subscribePaneStreamIsCallerFed() async throws {
        let fake = FakeDaemonClient()
        let stream = try fake.subscribePane(paneId: "p9")
        #expect(fake.subscribePaneCalls == ["p9"])
        let event = PaneEvent.stateChanged(
            StateChangedEvent(paneId: "p9", state: .shutdown)
        )
        fake.lastPaneEventContinuation?.yield(event)
        fake.lastPaneEventContinuation?.finish()
        var received: [PaneEvent] = []
        for await received1 in stream { received.append(received1) }
        // PaneEvent isn't Equatable (it carries an IOSurfaceRef
        // payload). Switch on the one received entry instead.
        #expect(received.count == 1)
        if case let .stateChanged(state) = received.first {
            #expect(state.paneId == "p9")
            #expect(state.state == .shutdown)
        } else {
            Issue.record("expected stateChanged event, got \(String(describing: received.first))")
        }
    }
}
