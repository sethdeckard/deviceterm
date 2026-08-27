// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
@testable import Daemon
import DaemonProtocol
import Foundation
import Testing
@preconcurrency import XPC

// XPCServer / XPCConnection: drive the full dispatch path
// (envelope → registry → handler → reply) via an in-process
// anonymous XPC pair so unit coverage doesn't need launchd or a
// real mach service.
//
// Tests pin: round-trip of a daemon-wide method through XPC;
// audit-token capture lights up `DispatchPeerContext.transport
// == .xpc` for the handler; malformed payloads (no `type`
// discriminator, unknown method) reply with the right envelope.

@Test
func roundTripsADaemonWideRPC() async throws {
    let (sentTransport, registry) = makeTransportObservingRegistry()
    let server = XPCServer(methods: registry)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    sendRequest(envelopeId: 42, method: "echo.transport", client: clientPair)
    let reply = try await replyBox.awaitReply()
    let observed = await sentTransport.value
    #expect(observed == "xpc")
    let body = decodeResultPayload(reply: reply)
    #expect(body == #"{"transport":"xpc"}"#)
}

@Test
func malformedMessageWithoutTypeIsIgnored() async throws {
    let (sentTransport, registry) = makeTransportObservingRegistry()
    let server = XPCServer(methods: registry)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    // Send a dictionary without the `type` discriminator. The
    // server should drop it without ever dispatching to the
    // registry. The observer captures only successful dispatches.
    let badMessage = xpc_dictionary_create(nil, nil, 0)
    xpc_connection_send_message(clientPair, badMessage)
    // Brief delay so any erroneous dispatch would have time to
    // run before we sample.
    try await Task.sleep(nanoseconds: 50_000_000)
    let observed = await sentTransport.value
    #expect(observed.isEmpty)
}

@Test
func peerCloseDropsServerRegistryEntry() async throws {
    let registry = MethodRegistry()
    let server = XPCServer(methods: registry)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    // Round-trip one envelope to confirm the connection accepted.
    sendRequest(envelopeId: 1, method: "no.such.method", client: clientPair)
    _ = try await replyBox.awaitReply()
    var count = await server.connectionCount
    #expect(count == 1)

    // Cancel the peer side; libxpc delivers an error event to
    // the server's connection actor, which closes itself and
    // tells the server to remove its registry entry.
    xpc_connection_cancel(clientPair)

    // Poll briefly for the async close → removeConnection path
    // to land. The actor hops between the libxpc event handler,
    // the connection actor's `close`, and the server actor's
    // `removeConnection`, so a fixed sleep would be racy. 500 ms
    // is comfortably wider than the observed plumbing latency.
    let deadline = Date().addingTimeInterval(0.5)
    while Date() < deadline {
        count = await server.connectionCount
        if count == 0 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(count == 0)
}

@Test
func unknownMethodRepliesWithMethodNotFound() async throws {
    let registry = MethodRegistry()
    let server = XPCServer(methods: registry)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    sendRequest(envelopeId: 99, method: "no.such.method", client: clientPair)
    let reply = try await replyBox.awaitReply()
    let envelope = try decodeEnvelope(reply: reply)
    if case let .error(error) = envelope.body {
        #expect(error.code == RPCErrorCode.methodNotFound)
    } else {
        Issue.record("expected error body, got \(envelope.body)")
    }
}

@Test
func oneWayNotificationRunsHandlerAndSendsNoReply() async throws {
    // A request with no `id` is a one-way notification: the handler runs
    // but the dispatcher sends nothing back. We check for "no reply" by
    // following the notification with a normal request: the single reply
    // that comes back is the normal request's, not the notification's.
    let notifyBox = StringBox()
    let notifyHandler: MethodRegistry.Handler = { _ in
        await notifyBox.set("ran")
        return Data(#"{"notify":true}"#.utf8)
    }
    let echoHandler: MethodRegistry.Handler = { _ in
        let value = DispatchPeerContext.current?.transport.rawValue ?? ""
        return Data(#"{"transport":"\#(value)"}"#.utf8)
    }
    let registry = MethodRegistry(handlers: [
        "test.notify": .daemonWide(notifyHandler),
        "echo.transport": .daemonWide(echoHandler)
    ])
    let server = XPCServer(methods: registry)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    sendNotification(method: "test.notify", client: clientPair)
    sendRequest(envelopeId: 7, method: "echo.transport", client: clientPair)

    let reply = try await replyBox.awaitReply()
    #expect(decodeResultPayload(reply: reply) == #"{"transport":"xpc"}"#)
    // The notification handler runs as its own task, so it may not have run
    // by the time the echo reply arrives, so poll for it rather than assume
    // ordering.
    #expect(try await poll { await notifyBox.value == "ran" })
    // The single reply we received is the echo. A settle then checks for an
    // out-of-order late notification reply (a stronger signal than a point
    // sample, though it can't rule one out for all time).
    try await Task.sleep(nanoseconds: 40_000_000)
    #expect(await replyBox.receivedCount == 1)
}

@Test
func surfaceDrainNotificationTearsDownTheSubscription() async throws {
    // Subscribe to a pane over XPC, then send a `pane.surfaceDrain`
    // notification keyed by the subscribe request id. The transport
    // intercepts it, cancels the subscription task, and unregisters the
    // surface-delivery entry, so the registry's subscriber count returns to
    // zero even though the drain carried no id and no token.
    let registry = PaneSubscriptionRegistry()
    let coordinator = PaneCoordinator(subscriptionRegistry: registry)
    let session = UUID()
    let (paneId, _) = try await makeSimPane(coordinator: coordinator, session: session)

    let methods = MethodRegistry(subscriptions: [
        RPCMethod.paneSubscribe.rawValue: .daemonWide(
            PaneMethods.subscribe(paneCoordinator: coordinator)
        )
    ])
    let server = XPCServer(methods: methods, subscriptionRegistry: registry)
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    let subscribeId: UInt32 = 11
    let subscribeParams = try JSONEncoder().encode(
        PaneMethods.SubscribeParams(paneId: paneId.uuidString)
    )
    sendRequest(
        envelopeId: subscribeId,
        method: RPCMethod.paneSubscribe.rawValue,
        params: subscribeParams,
        client: clientPair
    )
    _ = try await replyBox.awaitReply()

    // The XPC connection registered a surface-delivery entry for the pane.
    try await expectSubscriberCount(registry, paneId: paneId, equals: 1)

    let drainParams = try JSONEncoder().encode(
        SurfaceDrainParams(paneId: paneId.uuidString, subscribeRequestId: subscribeId)
    )
    sendNotification(
        method: RPCMethod.paneSurfaceDrain.rawValue,
        client: clientPair,
        params: drainParams
    )
    // Both the surface-delivery registry entry and the coordinator's own
    // subscriber return to zero.
    try await expectSubscriberCount(registry, paneId: paneId, equals: 0)
    var coordCount = await coordinator.subscriberCount(paneId: paneId)
    let deadline = Date().addingTimeInterval(0.5)
    while coordCount != 0, Date() < deadline {
        try await Task.sleep(nanoseconds: 5_000_000)
        coordCount = await coordinator.subscriberCount(paneId: paneId)
    }
    #expect(coordCount == 0)
}

@Test
func drainRacingSubscribeTearsDownRegardlessOfOrder() async throws {
    // A `pane.surfaceDrain` sent just before its `pane.subscribe`: send the
    // drain first and let it settle (biasing toward, without guaranteeing,
    // the tombstone branch), then subscribe. Whichever branch runs, the
    // subscription is torn down; both registries return to zero.
    let registry = PaneSubscriptionRegistry()
    let coordinator = PaneCoordinator(subscriptionRegistry: registry)
    let backend = DrainTestBackend()
    let paneId = try await makeDevicePane(coordinator: coordinator, backend: backend)
    let server = XPCServer(
        methods: subscribeOnlyRegistry(coordinator),
        subscriptionRegistry: registry
    )
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    let subscribeId: UInt32 = 21
    let drainParams = try JSONEncoder().encode(
        SurfaceDrainParams(paneId: paneId.uuidString, subscribeRequestId: subscribeId)
    )
    sendNotification(
        method: RPCMethod.paneSurfaceDrain.rawValue,
        client: clientPair,
        params: drainParams
    )
    // A settle so the drain is very likely processed (tombstoned) before
    // the subscribe lands. This biases the interleaving toward the
    // tombstone path but isn't a hard barrier (the transport can't expose
    // one). The asserted invariant holds either way: whichever order the
    // two callbacks run, the subscription ends torn down, not streaming.
    try await Task.sleep(nanoseconds: 40_000_000)
    sendRequest(
        envelopeId: subscribeId,
        method: RPCMethod.paneSubscribe.rawValue,
        params: try JSONEncoder().encode(PaneMethods.SubscribeParams(paneId: paneId.uuidString)),
        client: clientPair
    )

    // Positive evidence: the subscribe was actually handled (its device
    // setup reached `registerLeaseToken`). Without this the zero-count
    // assertions below could pass against the untouched initial state.
    #expect(try await poll { backend.registeredTokenCount >= 1 })
    // Yet it was torn down: the subscription doesn't survive as a
    // streamer. (We assert only the teardown invariant, which holds for
    // either interleaving; whether a response was sent depends on whether
    // the drain won the race, which the transport can't make deterministic,
    // so it isn't asserted here.)
    try await expectSubscriberCount(registry, paneId: paneId, equals: 0)
    try await expectCoordinatorSubscriberCount(coordinator, paneId: paneId, equals: 0)
}

@Test
func drainWhileSetupParkedTearsDown() async throws {
    // A drain sent while subscription setup is provably parked mid-handler
    // (the gate holds it at `registerLeaseToken`). The subscription is torn
    // down. Whether the drain is *processed* before setup resumes (the
    // synchronous-terminal path vs. cancel-the-streaming-task path) isn't
    // transport-deterministic, so only the teardown invariant is asserted.
    let registry = PaneSubscriptionRegistry()
    let coordinator = PaneCoordinator(subscriptionRegistry: registry)
    let backend = DrainTestBackend(gated: true)
    let paneId = try await makeDevicePane(coordinator: coordinator, backend: backend)
    let server = XPCServer(
        methods: subscribeOnlyRegistry(coordinator),
        subscriptionRegistry: registry
    )
    let (listener, clientPair) = makeAnonymousPair()
    let replyBox = ReplyBox()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupClient(clientPair, replyBox: replyBox)

    let subscribeId: UInt32 = 31
    sendRequest(
        envelopeId: subscribeId,
        method: RPCMethod.paneSubscribe.rawValue,
        params: try JSONEncoder().encode(PaneMethods.SubscribeParams(paneId: paneId.uuidString)),
        client: clientPair
    )
    // Wait until setup parks inside `registerLeaseToken`: positive
    // evidence the subscribe is mid-flight. The coordinator subscriber is
    // already installed at this point (added before the device block), so
    // the zero-count assertions below are a real teardown, not a vacuous
    // initial state.
    #expect(try await poll { await backend.gate.isWaiting })
    #expect(await coordinator.subscriberCount(paneId: paneId) == 1)
    let drainParams = try JSONEncoder().encode(
        SurfaceDrainParams(paneId: paneId.uuidString, subscribeRequestId: subscribeId)
    )
    sendNotification(
        method: RPCMethod.paneSurfaceDrain.rawValue,
        client: clientPair,
        params: drainParams
    )
    // The gate holds setup parked at `registerLeaseToken`, which is the
    // deterministic part. This settle gives the drain callback time to run
    // while parked before we release the gate; even if it hadn't, the
    // asserted teardown holds either way.
    try await Task.sleep(nanoseconds: 40_000_000)
    await backend.gate.open()

    // Torn down either way. As above, whether a response was suppressed
    // depends on the drain winning the race (not transport-deterministic),
    // so only the teardown invariant is asserted.
    try await expectSubscriberCount(registry, paneId: paneId, equals: 0)
    try await expectCoordinatorSubscriberCount(coordinator, paneId: paneId, equals: 0)
}

@Test
func subscriptionEventsFlowWhileAnotherRequestIsParked() async throws {
    // Each GUI lane is a shared XPC connection, and the pane lane multiplexes
    // every live pane. Were server dispatch serialized across requests, any
    // parked handler on a lane would stall its event streams. Pin the
    // transport capability independently of the client's lane routing: a pane
    // subscription keeps delivering `evt` frames before, during, and after a
    // second request is parked mid-handler, and the peer is never torn down.
    let registry = PaneSubscriptionRegistry()
    let coordinator = PaneCoordinator(subscriptionRegistry: registry)
    let session = UUID()
    let (paneId, backend) = try await makeSimPane(coordinator: coordinator, session: session)
    let gate = DrainGate()
    let parkedHandler: MethodRegistry.Handler = { _ in
        await gate.wait()
        return Data(#"{"parked":true}"#.utf8)
    }
    let methods = MethodRegistry(
        handlers: ["test.parked": .daemonWide(parkedHandler)],
        subscriptions: [
            RPCMethod.paneSubscribe.rawValue: .daemonWide(
                PaneMethods.subscribe(paneCoordinator: coordinator)
            )
        ]
    )
    let server = XPCServer(methods: methods, subscriptionRegistry: registry)
    let (listener, clientPair) = makeAnonymousPair()
    let inbound = EnvelopeLog()
    await server.bind(listener: listener)
    defer { Task { await server.stop() } }
    setupLoggingClient(clientPair, log: inbound)

    sendRequest(
        envelopeId: 51,
        method: RPCMethod.paneSubscribe.rawValue,
        params: try JSONEncoder().encode(PaneMethods.SubscribeParams(paneId: paneId.uuidString)),
        client: clientPair
    )
    #expect(try await poll { await inbound.responseCount == 1 })

    // Subscribing replays the pane's orientation. Let that settle before
    // turning the display: these counts are exact, and a replay still in
    // flight when the first turn's event lands would skip the count being
    // polled for.
    //
    // Each turn is to a *different* orientation, because the coordinator
    // publishes only on a change; repeating one would emit nothing and the
    // count would stall.
    let orientationEvent = PaneEventName.orientationChanged.rawValue
    #expect(try await poll { await inbound.eventCount(method: orientationEvent) == 1 })

    // Before: a display turn reaches the client as an `evt`.
    backend.turnDisplay(to: .landscapeLeft)
    #expect(try await poll { await inbound.eventCount(method: orientationEvent) == 2 })

    // Park a second request on the same connection, waiting for positive
    // evidence it is suspended inside its handler rather than a timed guess.
    sendRequest(envelopeId: 52, method: "test.parked", client: clientPair)
    #expect(try await poll { await gate.isWaiting })

    // During: the parked handler has not stalled the subscription.
    backend.turnDisplay(to: .portrait)
    #expect(try await poll { await inbound.eventCount(method: orientationEvent) == 3 })

    await gate.open()
    #expect(try await poll { await inbound.responseCount == 2 })

    // After: still streaming on a connection that was never torn down.
    backend.turnDisplay(to: .landscapeRight)
    #expect(try await poll { await inbound.eventCount(method: orientationEvent) == 4 })
    #expect(await server.connectionCount == 1)
    #expect(await coordinator.subscriberCount(paneId: paneId) == 1)
}

// MARK: - Test plumbing

/// Every inbound envelope, so a test can count responses and `evt` frames
/// independently. `ReplyBox` keeps only the latest reply, which cannot
/// distinguish a stalled event stream from a delivered one.
private actor EnvelopeLog {
    private var envelopes: [RPCEnvelope] = []

    var responseCount: Int {
        envelopes.count { $0.type == .response }
    }

    func eventCount(method: String) -> Int {
        envelopes.count { $0.type == .event && $0.method == method }
    }

    func record(_ envelope: RPCEnvelope) {
        envelopes.append(envelope)
    }
}

/// Wire the test client to decode and log every inbound envelope. The
/// `ReplyBox` variant in `setupClient` stores only the newest message.
private func setupLoggingClient(_ client: xpc_connection_t, log: EnvelopeLog) {
    xpc_connection_set_event_handler(client) { event in
        guard
            xpc_get_type(event) == XPC_TYPE_DICTIONARY,
            let envelope = try? decodeEnvelope(reply: event)
        else {
            return
        }
        Task { await log.record(envelope) }
    }
    xpc_connection_resume(client)
}

/// A registry exposing only `pane.subscribe` (daemon-wide so the test's
/// unauthenticated connection can reach it), wired to `coordinator`.
private func subscribeOnlyRegistry(_ coordinator: PaneCoordinator) -> MethodRegistry {
    MethodRegistry(subscriptions: [
        RPCMethod.paneSubscribe.rawValue: .daemonWide(
            PaneMethods.subscribe(paneCoordinator: coordinator)
        )
    ])
}

/// A one-shot open/wait gate. `isWaiting` lets a test poll until the
/// awaiter has parked, so the sequencing is deterministic, not timed.
private actor DrainGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    var isWaiting: Bool { continuation != nil }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { self.continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

// swiftlint:disable unneeded_throws_rethrows
/// A device backend for the drain tests. When `gated`, its
/// `registerLeaseToken` parks on the gate so a test can inject a drain
/// while subscription setup is suspended mid-handler. `@unchecked
/// Sendable`: `registerCount` is read/written only under `lock`; `gated`
/// is immutable.
private final class DrainTestBackend: DeviceBackend, @unchecked Sendable {
    let capabilities = DeviceBackendCapabilities.physicalDevice.withoutLocation
    let gate = DrainGate()
    private let gated: Bool
    // Positive evidence that subscription setup reached the device
    // registration path. Bumped under a lock; read after awaiting.
    private let lock = NSLock()
    private var registerCount = 0
    var registeredTokenCount: Int { lock.lock(); defer { lock.unlock() }; return registerCount }

    init(gated: Bool = false) { self.gated = gated }

    func startFrames(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void,
        onDisconnect: @escaping @Sendable () -> Void
    ) throws {}
    func stopFrames() {}
    func pixelDimensions() -> (Int?, Int?) { (nil, nil) }

    // No display to observe; the pane keeps its last commanded orientation.
    func startDisplayOrientation(onChange: @escaping @Sendable (Orientation) -> Void) -> Bool { false }
    func stopDisplayOrientation() {}
    func currentDisplayOrientation() -> Orientation? { nil }
    func tapDown(at point: CGPoint, generation: UInt64) throws {}
    func tapUp(at point: CGPoint, generation: UInt64) throws {}
    func twoFingerDown(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws {}
    func twoFingerUp(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws {}
    func keyDown(hidUsage: UInt32, generation: UInt64) throws {}
    func keyUp(hidUsage: UInt32, generation: UInt64) throws {}
    func pressHardwareButton(_ button: HardwareButton, generation: UInt64) throws {}
    // swiftlint:disable:next async_without_await
    func rotate(to orientation: Orientation, generation: UInt64) async throws -> Bool { true }
    func rotateCrown(delta: Double, generation: UInt64) throws {}
    func accessibilityFrontmostTree() throws -> [String: Any] { [:] }
    func accessibilityElement(at pixelPoint: CGPoint) throws -> [String: Any] { [:] }
    func shutdownBackend() {}

    func registerLeaseToken(_ token: UUID, connectionId: UInt64) async {
        lock.withLock { registerCount += 1 }
        if gated { await gate.wait() }
    }
}
// swiftlint:enable unneeded_throws_rethrows

private func makeDevicePane(coordinator: PaneCoordinator, backend: DeviceBackend) async throws -> UUID {
    let result = try await coordinator.createPane(
        target: .device(deviceId: "dev-drain-race"),
        sessionId: UUID(),
        acquire: { PaneCoordinator.AcquiredBackend(backend: backend, family: "phone", deviceType: "iPhone") }
    )
    return result.paneId
}

/// Poll the coordinator's subscriber count until it matches.
private func expectCoordinatorSubscriberCount(
    _ coordinator: PaneCoordinator,
    paneId: UUID,
    equals expected: Int
) async throws {
    let deadline = Date().addingTimeInterval(0.5)
    var count = await coordinator.subscriberCount(paneId: paneId)
    while count != expected, Date() < deadline {
        try await Task.sleep(nanoseconds: 5_000_000)
        count = await coordinator.subscriberCount(paneId: paneId)
    }
    #expect(count == expected)
}

// swiftlint:disable unneeded_throws_rethrows
/// A no-op backend, so a subscribe reaches a real record without a live
/// CoreSimulator.
///
/// `@unchecked Sendable`: the only mutable state is the orientation
/// observation hook, which has no synchronization of its own. These tests
/// keep it safe by ordering rather than locking: the coordinator installs
/// it during `createPane`, the test drives `turnDisplay` afterwards from
/// one thread, and nothing here tears the pane down while a turn is in
/// flight.
private final class NoopBackend: DeviceBackend, @unchecked Sendable {
    let capabilities = DeviceBackendCapabilities.simulator.withoutLocation
    /// Observation hook, so a test can turn the display the way the
    /// bridge's callback does. Orientation events are the only pane events
    /// these transport tests can drive on demand.
    private(set) var onDisplayOrientation: (@Sendable (Orientation) -> Void)?

    func startFrames(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void,
        onDisconnect: @escaping @Sendable () -> Void
    ) throws {}
    func stopFrames() {}
    func pixelDimensions() -> (Int?, Int?) { (nil, nil) }
    func startDisplayOrientation(onChange: @escaping @Sendable (Orientation) -> Void) -> Bool {
        onDisplayOrientation = onChange
        return true
    }
    func stopDisplayOrientation() { onDisplayOrientation = nil }
    func currentDisplayOrientation() -> Orientation? { nil }
    func turnDisplay(to orientation: Orientation) { onDisplayOrientation?(orientation) }
    func tapDown(at point: CGPoint, generation: UInt64) throws {}
    func tapUp(at point: CGPoint, generation: UInt64) throws {}
    func twoFingerDown(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws {}
    func twoFingerUp(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws {}
    func keyDown(hidUsage: UInt32, generation: UInt64) throws {}
    func keyUp(hidUsage: UInt32, generation: UInt64) throws {}
    func pressHardwareButton(_ button: HardwareButton, generation: UInt64) throws {}
    // swiftlint:disable:next async_without_await
    func rotate(to orientation: Orientation, generation: UInt64) async throws -> Bool { true }
    func rotateCrown(delta: Double, generation: UInt64) throws {}
    func accessibilityFrontmostTree() throws -> [String: Any] { [:] }
    func accessibilityElement(at pixelPoint: CGPoint) throws -> [String: Any] { [:] }
    func shutdownBackend() {}
}
// swiftlint:enable unneeded_throws_rethrows

/// Create a hermetic sim-backed pane whose backend is a no-op mock.

private func makeSimPane(
    coordinator: PaneCoordinator,
    session: UUID
) async throws -> (paneId: UUID, backend: NoopBackend) {
    let backend = NoopBackend()
    let result = try await coordinator.createPane(
        target: .sim(udid: "udid-drain"),
        sessionId: session,
        acquire: { PaneCoordinator.AcquiredBackend(backend: backend, family: "phone", deviceType: "iPhone") }
    )
    return (result.paneId, backend)
}

/// Poll the registry's subscriber count until it matches (the XPC teardown
/// plumbing hops across actors, so a fixed sleep would be racy).
private func expectSubscriberCount(
    _ registry: PaneSubscriptionRegistry,
    paneId: UUID,
    equals expected: Int
) async throws {
    let deadline = Date().addingTimeInterval(0.5)
    var count = await registry.subscriberCount(paneId: paneId)
    while count != expected, Date() < deadline {
        try await Task.sleep(nanoseconds: 5_000_000)
        count = await registry.subscriberCount(paneId: paneId)
    }
    #expect(count == expected)
}

/// Build a registry whose `echo.transport` handler captures the
/// `DispatchPeerContext.current?.transport` rawValue into a
/// shared box and returns it. Confirms the XPC dispatcher binds
/// the task-local with `.xpc` per the production wiring.
private func makeTransportObservingRegistry() -> (StringBox, MethodRegistry) {
    let box = StringBox()
    let handler: MethodRegistry.Handler = { _ in
        let value = DispatchPeerContext.current?.transport.rawValue ?? ""
        await box.set(value)
        let payload = #"{"transport":"\#(value)"}"#
        return Data(payload.utf8)
    }
    let registry = MethodRegistry(
        handlers: [
            "echo.transport": .daemonWide(handler)
        ]
    )
    return (box, registry)
}
