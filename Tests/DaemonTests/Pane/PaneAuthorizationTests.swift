// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// Pane-authorization tests: the central security contract of the pane
// gate, exercised on the actor with a real `PaneSubscriptionRegistry` where
// the surface lane matters. A `.session` principal reaches only its own
// panes; a foreign pane is indistinguishable from an unknown one (no
// existence oracle); the validated `.guiPeer` spans sessions; an ownership
// transfer (adoption) revokes the prior owner's subscription and access; and
// an in-flight paced gesture is fenced the moment the pane transfers. The
// surface-hook guard drives the actual registry (the coordinator registers a
// delivery hook only *after* authorizing, so rejected foreign subscriptions
// create no registry entry or surface lease); a foreign subscribe therefore
// leaves no `(pane, connection)` entry; the anonymous-XPC transport
// teardown itself is covered in `XPCServerRoundtripTests`. A mock backend
// drives the core, so no CoreSimulator or device is touched.

// swiftlint:disable unneeded_throws_rethrows

private extension PaneCoordinator {
    func makeSimPane(
        udid: String,
        session: UUID,
        backend: any DeviceBackend = MockDeviceBackend()
    ) async throws -> PaneCreateResult {
        try await createPane(
            target: .sim(udid: udid),
            sessionId: session,
            acquire: { AcquiredBackend(backend: backend, family: "phone", deviceType: "iPhone") }
        )
    }
}

/// A real subscription context bound to `connectionId`, so a test can assert
/// against `PaneSubscriptionRegistry.hasEntry(paneId:connectionId:)` whether
/// the coordinator wired a surface-delivery hook for that connection.
private func makeContext(connectionId: UInt64) -> SubscriptionContext {
    SubscriptionContext(
        subscriptionToken: UUID(),
        connectionId: connectionId,
        lifecycle: SubscriptionLifecycle(),
        surfaceDelivery: { _ in }
    )
}

@Test("a session cannot drive a pane owned by another session; the owner can")
func foreignSessionInputRejected() async throws {
    let coordinator = PaneCoordinator()
    let owner = UUID()
    let attacker = UUID()
    let pane = try await coordinator.makeSimPane(udid: "auth-1", session: owner)

    await #expect(throws: PaneError.notFound(paneId: pane.paneId)) {
        try await coordinator.tap(paneId: pane.paneId, as: .session(attacker), x: 0.5, y: 0.5)
    }
    // The owner still reaches it.
    try await coordinator.tap(paneId: pane.paneId, as: .session(owner), x: 0.5, y: 0.5)
}

@Test("a foreign pane throws the identical error to an unknown pane (no existence oracle)")
func foreignPaneIndistinguishableFromUnknown() async throws {
    let coordinator = PaneCoordinator()
    let owner = UUID()
    let attacker = UUID()
    let pane = try await coordinator.makeSimPane(udid: "auth-2", session: owner)
    let randomId = UUID()

    func captureError(_ paneId: UUID) async -> PaneError? {
        do {
            try await coordinator.tap(paneId: paneId, as: .session(attacker), x: 0, y: 0)
            return nil
        } catch let error as PaneError {
            return error
        } catch {
            return nil
        }
    }
    let foreign = await captureError(pane.paneId)
    let unknown = await captureError(randomId)
    #expect(foreign != nil)
    // Same case *and* associated value shape: a distinct "forbidden" code
    // would itself reveal that the UUID names a real, live, other-session
    // pane. Both must be `notFound`.
    if case .notFound = foreign, case .notFound = unknown {
        // ok
    } else {
        Issue.record("expected both notFound, got \(String(describing: foreign)) / \(String(describing: unknown))")
    }
}

@Test("the validated GUI peer reaches panes across sessions")
func guiPeerSpansSessions() async throws {
    let coordinator = PaneCoordinator()
    let paneA = try await coordinator.makeSimPane(udid: "auth-a", session: UUID())
    let paneB = try await coordinator.makeSimPane(udid: "auth-b", session: UUID())
    // Each owned by a different session; the GUI peer drives both.
    try await coordinator.tap(paneId: paneA.paneId, as: .guiPeer, x: 0.1, y: 0.1)
    try await coordinator.tap(paneId: paneB.paneId, as: .guiPeer, x: 0.2, y: 0.2)
}

@Test("a foreign session cannot subscribe to another session's pane")
func foreignSessionSubscribeRejected() async throws {
    let coordinator = PaneCoordinator()
    let owner = UUID()
    let attacker = UUID()
    let pane = try await coordinator.makeSimPane(udid: "auth-sub", session: owner)
    await #expect(throws: PaneError.notFound(paneId: pane.paneId)) {
        _ = try await coordinator.subscribe(paneId: pane.paneId, as: .session(attacker))
    }
    #expect(await coordinator.subscriberCount(paneId: pane.paneId) == 0)
}

@Test("a foreign subscribe installs no surface-delivery hook; an authorized one does")
func foreignSubscribeInstallsNoSurfaceHook() async throws {
    // The frame-leak guard, run through the real registry: the coordinator
    // registers a surface-delivery hook only after `authorize`, so a foreign
    // subscribe, rejected before registration, leaves no `(pane, conn)`
    // entry, and a real frame delivered to the victim pane reaches nothing on
    // the attacker's connection. The `hasEntry` query is what makes the
    // *absence* of a side-band hook assertable (subscriber counts can't).
    let registry = PaneSubscriptionRegistry()
    let coordinator = PaneCoordinator(subscriptionRegistry: registry)
    let owner = UUID()
    let attacker = UUID()
    let pane = try await coordinator.makeSimPane(udid: "auth-hook", session: owner)

    let attackerConnection: UInt64 = 77
    await #expect(throws: PaneError.notFound(paneId: pane.paneId)) {
        _ = try await coordinator.subscribe(
            paneId: pane.paneId,
            as: .session(attacker),
            context: makeContext(connectionId: attackerConnection)
        )
    }
    #expect(await registry.hasEntry(paneId: pane.paneId, connectionId: attackerConnection) == false)
    #expect(await registry.subscriberCount(paneId: pane.paneId) == 0)

    // Positive control: the owner subscribing over the same path *does* install
    // the hook, so the absence above is the authorization gate withholding it,
    // not registration being broken for everyone.
    let ownerConnection: UInt64 = 88
    _ = try await coordinator.subscribe(
        paneId: pane.paneId,
        as: .session(owner),
        context: makeContext(connectionId: ownerConnection)
    )
    #expect(await registry.hasEntry(paneId: pane.paneId, connectionId: ownerConnection) == true)
}

@Test("adoption revokes the prior owner's subscription and access; the adopter gains both")
func adoptionRevokesPriorOwnerAndTransfersToAdopter() async throws {
    let coordinator = PaneCoordinator()
    let owner = UUID()
    let recovery = UUID()
    let pane = try await coordinator.makeSimPane(udid: "auth-adopt", session: owner)

    // The prior owner subscribes (UDS/JSON, no context).
    let (_, stream) = try await coordinator.subscribe(paneId: pane.paneId, as: .session(owner))

    // Adopt the orphan into the recovery session (prior owner reported dead).
    _ = try await coordinator.createPane(
        target: .sim(udid: "auth-adopt"),
        sessionId: recovery,
        isOwnerSessionAlive: { _ in false },
        acquire: {
            PaneCoordinator.AcquiredBackend(backend: MockDeviceBackend(), family: "phone", deviceType: "iPhone")
        }
    )

    // The prior owner's stream is finished by the transfer's revocation:
    // if it weren't, this `for await` would never terminate.
    var post = 0
    for await _ in stream { post += 1 }

    // Prior owner has lost input + subscribe access; the adopter has both.
    await #expect(throws: PaneError.notFound(paneId: pane.paneId)) {
        try await coordinator.tap(paneId: pane.paneId, as: .session(owner), x: 0, y: 0)
    }
    try await coordinator.tap(paneId: pane.paneId, as: .session(recovery), x: 0.3, y: 0.3)
    let (recoveryId, recoveryStream) = try await coordinator.subscribe(paneId: pane.paneId, as: .session(recovery))
    await coordinator.unsubscribe(paneId: pane.paneId, subscriptionId: recoveryId)
    _ = recoveryStream
}

// MARK: - Input-generation fence

/// A backend that owns a real input generation (like `SimDeviceBackend`)
/// and records a `tapDown` only when it carries the *current* generation:
/// exactly what the coordinator's transfer quiesce invalidates. Lets a
/// hermetic test prove a paced gesture stops driving the device once the
/// pane transfers.
private final class GatingMockBackend: DeviceBackend, @unchecked Sendable {
    let capabilities = DeviceBackendCapabilities.simulator.withoutLocation
    private let gate = DispatchQueue(label: "test.gating.input")
    private var generation: UInt64 = 1
    private var taps: [CGPoint] = []

    var recordedTaps: [CGPoint] { gate.sync { taps } }

    func startFrames(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void,
        onDisconnect: @escaping @Sendable () -> Void
    ) throws {}
    func stopFrames() {}
    func pixelDimensions() -> (Int?, Int?) { (nil, nil) }

    // No display or reply to observe; rotation confirmation is unsupported.
    func startDisplayOrientation(onChange: @escaping @Sendable (Orientation) -> Void) -> Bool { false }
    func stopDisplayOrientation() {}
    func currentDisplayOrientation() -> Orientation? { nil }

    func currentInputGeneration() -> UInt64 { gate.sync { generation } }
    func isInputGenerationCurrent(_ generation: UInt64) -> Bool { gate.sync { generation == self.generation } }
    // swiftlint:disable:next async_without_await
    func quiesceInputForTransfer() async -> Bool {
        gate.sync { generation &+= 1 }
        return true
    }
    func resumeInput() { gate.sync { generation &+= 1 } }

    func tapDown(at point: CGPoint, generation: UInt64) throws {
        gate.sync { if generation == self.generation { taps.append(point) } }
    }
    func tapUp(at point: CGPoint, generation: UInt64) throws {}
    func twoFingerDown(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws {}
    func twoFingerUp(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws {}
    func keyDown(hidUsage: UInt32, generation: UInt64) throws {}
    func keyUp(hidUsage: UInt32, generation: UInt64) throws {}
    func pressHardwareButton(_ button: HardwareButton, generation: UInt64) throws {}
    func rotate(
        target: RotationTarget,
        confirmedOrientation: Orientation?,
        generation: UInt64
    ) throws -> BackendRotationOutcome {
        .confirmationUnsupported(target: target.orientation)
    }
    func rotateCrown(delta: Double, generation: UInt64) throws {}
    func accessibilityFrontmostTree() throws -> [String: Any] { [:] }
    func accessibilityElement(at pixelPoint: CGPoint) throws -> [String: Any] { [:] }
    func shutdownBackend() {}
}

@Test("a transfer fences an in-flight paced gesture — no stale send reaches the new owner")
func transferFencesInFlightGesture() async throws {
    let coordinator = PaneCoordinator()
    let owner = UUID()
    let recovery = UUID()
    let backend = GatingMockBackend()
    let pane = try await coordinator.makeSimPane(udid: "auth-fence", session: owner, backend: backend)

    // Start a long paced swipe as the owner; it yields at each inter-step
    // sleep, streaming `tapDown`s carrying the generation captured at
    // admission.
    async let gesture: Void = {
        _ = try? await coordinator.swipe(
            paneId: pane.paneId,
            as: .session(owner),
            fromX: 0,
            fromY: 0,
            toX: 1,
            toY: 1,
            durationMs: 2_000
        )
    }()

    // Let a few steps land, then adopt the pane into recovery: the transfer
    // quiesces input (bumping the backend generation).
    try await Task.sleep(nanoseconds: 60_000_000)
    #expect(backend.recordedTaps.count >= 1)
    _ = try await coordinator.createPane(
        target: .sim(udid: "auth-fence"),
        sessionId: recovery,
        isOwnerSessionAlive: { _ in false },
        acquire: {
            PaneCoordinator.AcquiredBackend(backend: MockDeviceBackend(), family: "phone", deviceType: "iPhone")
        }
    )

    // Capture the count *immediately* after the transfer, before awaiting
    // the gesture. A correct fence has already stopped new sends (the
    // gesture's captured generation is now stale, and the backend drops any
    // send carrying it). Assert stability across a window in which the
    // gesture would still be mid-swipe (its 2s hasn't elapsed). A broken
    // fence would emit ~9 more steps here.
    let atTransfer = backend.recordedTaps.count
    try await Task.sleep(nanoseconds: 150_000_000)
    #expect(backend.recordedTaps.count == atTransfer, "a stale gesture kept driving the new owner")

    // And the gesture stops promptly rather than running its full 2s.
    let deadline = Date().addingTimeInterval(1.5)
    await gesture
    #expect(Date() < deadline, "the fenced gesture didn't stop promptly")
}

/// A backend whose input can never be confirmed clean: its
/// `quiesceInputForTransfer` reports failure, standing in for a device
/// that still holds input after a failed release.
private final class UnquiescableBackend: DeviceBackend, @unchecked Sendable {
    let capabilities = DeviceBackendCapabilities.simulator.withoutLocation
    func startFrames(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void,
        onDisconnect: @escaping @Sendable () -> Void
    ) throws {}
    func stopFrames() {}
    func pixelDimensions() -> (Int?, Int?) { (nil, nil) }

    // No display or reply to observe; rotation confirmation is unsupported.
    func startDisplayOrientation(onChange: @escaping @Sendable (Orientation) -> Void) -> Bool { false }
    func stopDisplayOrientation() {}
    func currentDisplayOrientation() -> Orientation? { nil }
    // swiftlint:disable:next async_without_await
    func quiesceInputForTransfer() async -> Bool { false }
    func tapDown(at point: CGPoint, generation: UInt64) throws {}
    func tapUp(at point: CGPoint, generation: UInt64) throws {}
    func twoFingerDown(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws {}
    func twoFingerUp(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws {}
    func keyDown(hidUsage: UInt32, generation: UInt64) throws {}
    func keyUp(hidUsage: UInt32, generation: UInt64) throws {}
    func pressHardwareButton(_ button: HardwareButton, generation: UInt64) throws {}
    func rotate(
        target: RotationTarget,
        confirmedOrientation: Orientation?,
        generation: UInt64
    ) throws -> BackendRotationOutcome {
        .confirmationUnsupported(target: target.orientation)
    }
    func rotateCrown(delta: Double, generation: UInt64) throws {}
    func accessibilityFrontmostTree() throws -> [String: Any] { [:] }
    func accessibilityElement(at pixelPoint: CGPoint) throws -> [String: Any] { [:] }
    func shutdownBackend() {}
}

@Test("a transfer aborts rather than flipping onto a device whose input can't be quiesced")
func transferAbortsWhenInputNotQuiesced() async throws {
    let coordinator = PaneCoordinator()
    let owner = UUID()
    let recovery = UUID()
    let pane = try await coordinator.makeSimPane(
        udid: "auth-unquiesce",
        session: owner,
        backend: UnquiescableBackend()
    )

    // Adopt the orphan (prior owner dead). Quiesce reports failure, so the
    // transfer aborts and the adoption throws rather than flipping ownership
    // onto a device that may still hold the prior owner's input.
    await #expect(throws: PaneError.inputNotQuiesced(paneId: pane.paneId)) {
        _ = try await coordinator.createPane(
            target: .sim(udid: "auth-unquiesce"),
            sessionId: recovery,
            isOwnerSessionAlive: { _ in false },
            acquire: {
                PaneCoordinator.AcquiredBackend(
                    backend: UnquiescableBackend(),
                    family: "phone",
                    deviceType: "iPhone"
                )
            }
        )
    }

    // Ownership did not flip: the pane was not adopted into recovery.
    #expect(await coordinator.panesForSession(recovery).isEmpty)
    #expect(await coordinator.panesForSession(owner).count == 1)
}

/// A backend whose input can't be quiesced on the *first* transfer attempt
/// but recovers afterward (e.g. an up-only release lands on the retry).
private final class RecoveringBackend: DeviceBackend, @unchecked Sendable {
    let capabilities = DeviceBackendCapabilities.simulator.withoutLocation
    private let gate = DispatchQueue(label: "test.recovering")
    private var quiesceCalls = 0
    func startFrames(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void,
        onDisconnect: @escaping @Sendable () -> Void
    ) throws {}
    func stopFrames() {}
    func pixelDimensions() -> (Int?, Int?) { (nil, nil) }

    // No display or reply to observe; rotation confirmation is unsupported.
    func startDisplayOrientation(onChange: @escaping @Sendable (Orientation) -> Void) -> Bool { false }
    func stopDisplayOrientation() {}
    func currentDisplayOrientation() -> Orientation? { nil }
    // swiftlint:disable:next async_without_await
    func quiesceInputForTransfer() async -> Bool {
        gate.sync {
            quiesceCalls += 1
            return quiesceCalls > 1  // first attempt blocks; a retry succeeds.
        }
    }
    func tapDown(at point: CGPoint, generation: UInt64) throws {}
    func tapUp(at point: CGPoint, generation: UInt64) throws {}
    func twoFingerDown(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws {}
    func twoFingerUp(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws {}
    func keyDown(hidUsage: UInt32, generation: UInt64) throws {}
    func keyUp(hidUsage: UInt32, generation: UInt64) throws {}
    func pressHardwareButton(_ button: HardwareButton, generation: UInt64) throws {}
    func rotate(
        target: RotationTarget,
        confirmedOrientation: Orientation?,
        generation: UInt64
    ) throws -> BackendRotationOutcome {
        .confirmationUnsupported(target: target.orientation)
    }
    func rotateCrown(delta: Double, generation: UInt64) throws {}
    func accessibilityFrontmostTree() throws -> [String: Any] { [:] }
    func accessibilityElement(at pixelPoint: CGPoint) throws -> [String: Any] { [:] }
    func shutdownBackend() {}
}

@Test("an adoption that first aborts on un-quiesced input succeeds once input recovers")
func adoptionRetrySucceedsAfterInputRecovers() async throws {
    let coordinator = PaneCoordinator()
    let owner = UUID()
    let recovery = UUID()
    let backend = RecoveringBackend()
    let pane = try await coordinator.makeSimPane(udid: "auth-recover", session: owner, backend: backend)

    func adopt() async throws {
        _ = try await coordinator.createPane(
            target: .sim(udid: "auth-recover"),
            sessionId: recovery,
            isOwnerSessionAlive: { _ in false },
            acquire: {
                PaneCoordinator.AcquiredBackend(backend: MockDeviceBackend(), family: "phone", deviceType: "iPhone")
            }
        )
    }

    // First attempt: input not yet clean → abort, ownership unchanged.
    await #expect(throws: PaneError.inputNotQuiesced(paneId: pane.paneId)) { try await adopt() }
    #expect(await coordinator.panesForSession(recovery).isEmpty)

    // Retry: input has recovered → the adoption completes (not a permanent
    // wedge).
    try await adopt()
    #expect(await coordinator.panesForSession(recovery).count == 1)
    #expect(await coordinator.panesForSession(owner).isEmpty)
}
// swiftlint:enable unneeded_throws_rethrows
