// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

// Backend-seam tests. A `MockDeviceBackend` stands in for a live
// CoreSimulator, which is what makes the coordinator's create / dedup /
// input-dispatch core reachable off the live track at all: these prove
// the coordinator routes input to whatever backend a pane carries,
// gates verbs on the backend's capabilities, and runs the
// dedup/adopt-orphan logic independent of the backend kind.

// The `throws` on the input primitives is required to satisfy the
// `DeviceBackend` protocol witnesses; the mock bodies don't throw, so
// the unneeded-throws rule is a false positive across this type.
// swiftlint:disable unneeded_throws_rethrows

/// Records the primitive calls the coordinator makes and reports a
/// configurable capability set. `@unchecked Sendable`: only the
/// `PaneCoordinator` actor mutates it during a call; tests read the
/// recorded calls after awaiting that call (a happens-before barrier).
final class MockDeviceBackend: DeviceBackend, @unchecked Sendable {
    let capabilities: DeviceBackendCapabilities
    private(set) var tapDownPoints: [CGPoint] = []
    private(set) var tapUpPoints: [CGPoint] = []
    private(set) var edgeDownPoints: [CGPoint] = []
    private(set) var edgeMovePoints: [CGPoint] = []
    private(set) var edgeUpPoints: [CGPoint] = []
    private(set) var edgeValues: [Int] = []
    private(set) var crownDeltas: [Double] = []
    private(set) var rotations: [Orientation] = []
    private(set) var buttons: [HardwareButton] = []
    private(set) var keyDownUsages: [UInt32] = []
    private(set) var keyUpUsages: [UInt32] = []
    private(set) var openAppSwitcherCalls = 0
    /// The `IndigoHIDEdge` value each `openAppSwitcher` call carried, so a test
    /// can assert the device swipe rotates with the pane's orientation.
    private(set) var openAppSwitcherEdges: [Int] = []
    private(set) var startFramesCalled = false
    private(set) var shutdownCalled = false
    /// What `currentDisplayOrientation()` reports, which is what the
    /// coordinator seeds a pane from. Nil models a backend with a source
    /// that has nothing to say yet.
    var displayOrientation: Orientation?
    /// When false, `startDisplayOrientation` refuses, modelling a display
    /// that vends no orientation source (a physical device, or a proxy
    /// missing `SimScreen`). The pane must still render.
    var displayOrientationAvailable = true
    private(set) var startDisplayOrientationCalls = 0
    private(set) var stopDisplayOrientationCalls = 0
    /// The observation callback the coordinator installed, so a test can
    /// deliver a display rotation the way the bridge would.
    private(set) var onDisplayOrientation: (@Sendable (Orientation) -> Void)?
    /// The same callback, deliberately **kept past teardown**, so a test can
    /// model a delivery already in flight when the pane was retired. The
    /// real bridge can do this: unregistering doesn't recall a block already
    /// dispatched on the callback queue.
    private(set) var installedCallback: (@Sendable (Orientation) -> Void)?
    /// The frame callback the coordinator installed. Captured (not
    /// dropped) so a test can drive surfaces through the pane's ordered
    /// publish pump.
    private(set) var onSurface: (@Sendable (PublishedSurface) -> Void)?
    /// Test gate: when set, `tapDown` parks the calling (actor) thread on
    /// a semaphore until `releaseTapDown()`, so a test can hold the
    /// `PaneCoordinator` actor and watch the surface pump's bounded
    /// retention while the actor-isolated consumer can't run. Off by
    /// default, so it doesn't affect the input-routing tests.
    var blockTapDown = false
    private let tapDownGate = DispatchSemaphore(value: 0)
    private let parkedLock = NSLock()
    private var parked = false
    /// True once a blocked `tapDown` has parked the actor.
    var tapDownParked: Bool {
        parkedLock.lock(); defer { parkedLock.unlock() }; return parked
    }
    /// Test gate: when set, the *first* `rotate` suspends until
    /// `releaseFirstRotate()`, so a test can hold one rotation mid-flight and
    /// prove a second rotation's broadcast can't overtake it (ordering).
    var blockFirstRotate = false
    private var rotateGate: CheckedContinuation<Void, Never>?
    private var rotateCount = 0
    private var firstRotateParked = false
    /// Remembers a release that raced ahead of the park, so the parking side
    /// resumes immediately instead of storing a continuation nobody wakes.
    private var rotateReleased = false
    /// True once the first `rotate` has parked on the gate.
    var firstRotateStarted: Bool {
        parkedLock.lock(); defer { parkedLock.unlock() }; return firstRotateParked
    }
    /// When true, the edge-touch primitives throw `unsupportedEdgeGesture`
    /// the way a backend with no edge path does (the protocol default). Also
    /// flips `supportsSystemEdgeGesture` off, so the App Switcher dispatches
    /// through the device path (the system swipe, or the Home double-press fallback).
    private let edgeUnsupported: Bool
    /// When true, `openAppSwitcher` throws `unsupportedEdgeGesture` (a backend
    /// with no system-swipe path), so the coordinator falls back to the Home
    /// double-press. The real physical-device backend implements the swipe, so
    /// this defaults off.
    private let appSwitcherUnsupported: Bool
    /// The per-command outcome `rotate` reports: `true` (reached the target)
    /// unless a test sets it false to model a rotation the device didn't make
    /// (fenced or failed-to-reach), so the coordinator's broadcast suppression
    /// can be exercised.
    private let rotateReaches: Bool

    /// A simulator-like backend routes a synthetic edge swipe to the system
    /// recognizer; a device-like one (`edgeUnsupported`) can't, so it takes
    /// the button realization of the App Switcher.
    var supportsSystemEdgeGesture: Bool { !edgeUnsupported }

    /// When false every generation reads as stale, modelling a pane a transfer
    /// has fenced. The protocol default answers true, which is what the
    /// routing tests want, so this only matters to a test that wants a paced
    /// gesture to stop mid-flight.
    var inputGenerationCurrent = true
    /// When true, `releaseHeldContact` reports the contact still down, the way
    /// a backend whose release send didn't land does.
    var failReleaseHeldContact = false
    /// When true, every touch primitive throws, modelling a gesture whose sends
    /// start failing partway.
    var failSends = false

    init(
        capabilities: DeviceBackendCapabilities = .simulator.withoutLocation,
        edgeUnsupported: Bool = false,
        appSwitcherUnsupported: Bool = false,
        rotateReaches: Bool = true
    ) {
        self.capabilities = capabilities
        self.edgeUnsupported = edgeUnsupported
        self.appSwitcherUnsupported = appSwitcherUnsupported
        self.rotateReaches = rotateReaches
    }

    func isInputGenerationCurrent(_ generation: UInt64) -> Bool { inputGenerationCurrent }

    func releaseHeldContact() -> Bool { !failReleaseHeldContact }

    func startFrames(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void
    ) throws {
        startFramesCalled = true
        self.onSurface = onFrame
    }

    func stopFrames() {}

    func pixelDimensions() -> (Int?, Int?) { (nil, nil) }

    // MARK: Display orientation

    func startDisplayOrientation(onChange: @escaping @Sendable (Orientation) -> Void) -> Bool {
        startDisplayOrientationCalls += 1
        guard displayOrientationAvailable else { return false }
        onDisplayOrientation = onChange
        installedCallback = onChange
        return true
    }

    func stopDisplayOrientation() {
        stopDisplayOrientationCalls += 1
        onDisplayOrientation = nil
    }

    func currentDisplayOrientation() -> Orientation? { displayOrientation }

    /// Deliver a display rotation, as the bridge's callback does.
    func emitDisplayOrientation(_ orientation: Orientation) {
        displayOrientation = orientation
        onDisplayOrientation?(orientation)
    }

    /// Release a parked `tapDown`.
    func releaseTapDown() { tapDownGate.signal() }

    /// Release a parked first `rotate` (or record the release so a rotation
    /// that parks later resumes immediately).
    func releaseFirstRotate() {
        let continuation: CheckedContinuation<Void, Never>? = parkedLock.withLock {
            rotateReleased = true
            let parked = rotateGate
            rotateGate = nil
            return parked
        }
        continuation?.resume()
    }

    func tapDown(at point: CGPoint, generation: UInt64) throws {
        if failSends { throw DeviceBackendError.notActive }
        tapDownPoints.append(point)
        if blockTapDown {
            parkedLock.lock(); parked = true; parkedLock.unlock()
            tapDownGate.wait()
        }
    }

    func tapUp(at point: CGPoint, generation: UInt64) throws {
        if failSends { throw DeviceBackendError.notActive }
        tapUpPoints.append(point)
    }

    func edgeTouchDown(at point: CGPoint, edge: Int, generation: UInt64) throws {
        if edgeUnsupported { throw DeviceBackendError.unsupportedEdgeGesture }
        edgeDownPoints.append(point)
        edgeValues.append(edge)
    }

    func edgeTouchMove(at point: CGPoint, edge: Int, generation: UInt64) throws {
        if edgeUnsupported { throw DeviceBackendError.unsupportedEdgeGesture }
        edgeMovePoints.append(point)
        edgeValues.append(edge)
    }

    func edgeTouchUp(at point: CGPoint, edge: Int, generation: UInt64) throws {
        if edgeUnsupported { throw DeviceBackendError.unsupportedEdgeGesture }
        edgeUpPoints.append(point)
        edgeValues.append(edge)
    }

    func twoFingerDown(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws {}

    func twoFingerUp(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws {}

    func keyDown(hidUsage: UInt32, generation: UInt64) throws { keyDownUsages.append(hidUsage) }

    func keyUp(hidUsage: UInt32, generation: UInt64) throws { keyUpUsages.append(hidUsage) }

    func pressHardwareButton(_ button: HardwareButton, generation: UInt64) throws { buttons.append(button) }

    func openAppSwitcher(edge: Int, generation: UInt64) throws {
        if appSwitcherUnsupported { throw DeviceBackendError.unsupportedEdgeGesture }
        openAppSwitcherEdges.append(edge)
        openAppSwitcherCalls += 1
    }

    func rotate(to orientation: Orientation, generation: UInt64) async throws -> Bool {
        let shouldBlock: Bool = parkedLock.withLock {
            rotations.append(orientation)
            rotateCount += 1
            return rotateCount == 1 && blockFirstRotate
        }
        if shouldBlock {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Store the continuation and publish `firstRotateParked` in the
                // same critical section, so a release that observes the flag
                // always finds the continuation. If a release already raced
                // ahead, resume at once instead of parking forever.
                let resumeNow: Bool = parkedLock.withLock {
                    if rotateReleased { return true }
                    rotateGate = continuation
                    firstRotateParked = true
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return rotateReaches
    }

    func rotateCrown(delta: Double, generation: UInt64) throws { crownDeltas.append(delta) }

    func accessibilityFrontmostTree() throws -> [String: Any] { [:] }

    func accessibilityElement(at pixelPoint: CGPoint) throws -> [String: Any] { [:] }

    func shutdownBackend() { shutdownCalled = true }
}
// swiftlint:enable unneeded_throws_rethrows

extension PaneCoordinator {
    /// Create a pane backed by `backend`, bypassing the CoreSimulator
    /// acquire path. The target's udid is arbitrary (no live sim is
    /// touched). Returns the create result.
    func createMockPane(
        udid: String,
        sessionId: UUID,
        backend: MockDeviceBackend,
        revision: UInt64? = nil,
        isOwnerSessionAlive: (@Sendable (UUID) async -> Bool)? = nil
    ) async throws -> PaneCreateResult {
        try await createPane(
            target: .sim(udid: udid),
            sessionId: sessionId,
            revision: revision,
            isOwnerSessionAlive: isOwnerSessionAlive,
            acquire: { AcquiredBackend(backend: backend, family: "phone", deviceType: "iPhone") }
        )
    }
}

@Test
func createPaneStartsFramesAndListsThePane() async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let backend = MockDeviceBackend()
    let result = try await coordinator.createMockPane(udid: "udid-a", sessionId: session, backend: backend)
    #expect(backend.startFramesCalled)
    #expect(result.family == "phone")
    // The mock's own set + a sim target. It takes the protocol's throwing
    // location defaults, so it reports the sim set *minus* location: a
    // backend must not advertise a verb its dispatch rejects.
    #expect(result.capabilities == backend.capabilities.wire)
    #expect(!result.capabilities.location)
    #expect(result.target == .sim(udid: "udid-a"))
    let panes = await coordinator.panesForSession(session)
    #expect(panes.count == 1)
    #expect(panes.first?.paneId == result.paneId)
    #expect(panes.first?.udid == "udid-a")
    #expect(panes.first?.capabilities == backend.capabilities.wire)
}

@Test
func deviceReAttachInSameSessionSkipsAcquire() async throws {
    // The attach handler's "release the keepalive when the backend wasn't
    // consumed" path hinges on this: an idempotent re-attach of an
    // already-mirrored device returns the existing pane WITHOUT invoking
    // `acquire`. If this regressed (acquire ran on every attach), the
    // handler would over-release; if dedup stopped skipping acquire, the
    // freshly-built backend + its tunnel keepalive retain would leak.
    let coordinator = PaneCoordinator()
    let session = UUID()
    var acquireCount = 0
    func attach() async throws -> PaneCreateResult {
        try await coordinator.createPane(
            target: .device(deviceId: "dev-1"),
            sessionId: session,
            acquire: {
                acquireCount += 1
                return PaneCoordinator.AcquiredBackend(
                    backend: StubDeviceBackend(),
                    family: "phone",
                    deviceType: "iPhone"
                )
            }
        )
    }
    let first = try await attach()
    let second = try await attach()
    #expect(acquireCount == 1, "re-attach should reuse the pane, not re-acquire the backend")
    #expect(first.paneId == second.paneId)
    let panes = await coordinator.panesForSession(session)
    #expect(panes.count == 1)
}

@Test
func stubDeviceBackendPaneReportsDeviceCapabilitiesAndTarget() async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let result = try await coordinator.createPane(
        target: .device(deviceId: "dev-1"),
        sessionId: session,
        acquire: {
            PaneCoordinator.AcquiredBackend(
                backend: StubDeviceBackend(),
                family: "phone",
                deviceType: "iPhone 17"
            )
        }
    )
    // The stub's own set, not `.physicalDevice`: it takes the protocol's
    // throwing location defaults, so it must report `location: false` or
    // the capability gate would advertise a verb its dispatch rejects.
    let expected = StubDeviceBackend().capabilities.wire
    #expect(result.capabilities == expected)
    #expect(result.target == .device(deviceId: "dev-1"))
    // The device set: touch/button/rotate/keyboard yes; crown/AX no.
    #expect(result.capabilities.touch && result.capabilities.button && result.capabilities.rotate)
    #expect(result.capabilities.key && result.capabilities.text)
    #expect(!result.capabilities.crown && !result.capabilities.accessibility)
    #expect(!result.capabilities.location)
    let panes = await coordinator.panesForSession(session)
    #expect(panes.first?.capabilities == expected)
    #expect(panes.first?.target == .device(deviceId: "dev-1"))
    // A device pane's identity key is its deviceId, surfaced in `udid`.
    #expect(panes.first?.udid == "dev-1")
}

@Test
func inputRoutesToThePanesBackend() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let result = try await coordinator.createMockPane(udid: "udid-b", sessionId: UUID(), backend: backend)
    try await coordinator.tap(paneId: result.paneId, as: .guiPeer, x: 0.25, y: 0.75)
    try await coordinator.rotate(paneId: result.paneId, as: .guiPeer, target: .absolute(.landscapeLeft))
    try await coordinator.pressButton(paneId: result.paneId, as: .guiPeer, button: .home)
    #expect(backend.tapDownPoints == [CGPoint(x: 0.25, y: 0.75)])
    #expect(backend.tapUpPoints == [CGPoint(x: 0.25, y: 0.75)])
    #expect(backend.rotations == [.landscapeLeft])
    #expect(backend.buttons == [.home])
}

@Test
func aTapHoldsContactForTheDwell() async throws {
    // A contact sent down and up back to back reaches the view and draws no
    // reaction from the controls it was measured against, so a dwell between
    // the two calls is what a tap needs to register. This measures the call,
    // not the interval the backend saw: the mock records points, not
    // timestamps.
    //
    // For an uncancelled tap the elapsed time is at least the dwell, and
    // scheduling can only lengthen it, so a lower bound is the stable
    // assertion.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let result = try await coordinator.createMockPane(udid: "udid-dwell", sessionId: UUID(), backend: backend)
    let start = ContinuousClock().now
    try await coordinator.tap(paneId: result.paneId, as: .guiPeer, x: 0.5, y: 0.5)
    #expect(ContinuousClock().now - start >= .milliseconds(SimInputSynthesis.tapDwellMs))
    // Exactly one down and one up: a passive dwell, where `activeDwell` emits
    // repeated downs.
    #expect(backend.tapDownPoints == [CGPoint(x: 0.5, y: 0.5)])
    #expect(backend.tapUpPoints == [CGPoint(x: 0.5, y: 0.5)])
}

@Test
func aCommandedRotationPublishesNothingByItself() async throws {
    // A command says where the device was told to point; it never says the
    // display turned. An orientation-locked app answers a rotate by leaving
    // the framebuffer exactly where it was, and a pane that turned on the
    // command alone would counter-rotate a portrait framebuffer forever.
    // So a rotate publishes nothing however well it went, and the only
    // event a subscriber sees here is the subscribe-time replay.
    //
    // Draining the stream to completion after unsubscribe makes this
    // deterministic: a wrongly-published event would sit buffered ahead of
    // the finish.
    func published(reaches: Bool, udid: String) async throws -> [Orientation] {
        let coordinator = PaneCoordinator()
        let backend = MockDeviceBackend(rotateReaches: reaches)
        let pane = try await coordinator.createMockPane(udid: udid, sessionId: UUID(), backend: backend)
        let (subscriptionId, stream) = try await coordinator.subscribe(paneId: pane.paneId, as: .guiPeer)
        try await coordinator.rotate(paneId: pane.paneId, as: .guiPeer, target: .absolute(.landscapeLeft))
        #expect(backend.rotations == [.landscapeLeft]) // the rotate was attempted either way
        await coordinator.unsubscribe(paneId: pane.paneId, subscriptionId: subscriptionId)
        var orientations: [Orientation] = []
        for await event in stream {
            if case let .orientationChanged(_, orientation) = event { orientations.append(orientation) }
        }
        #expect(orientations.first == .portrait) // the replay
        return Array(orientations.dropFirst())
    }
    #expect(try await published(reaches: true, udid: "rot-yes").isEmpty)
    #expect(try await published(reaches: false, udid: "rot-no").isEmpty)
}

@Test
func anObservedDisplayRotationPublishesOrientationChanged() async throws {
    // The other half of the split: presentation is published by observing
    // the display, whatever moved it. This is the path that makes a
    // rotation from outside deviceterm reach the pane at all.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: "disp-obs", sessionId: UUID(), backend: backend)
    let (subscriptionId, stream) = try await coordinator.subscribe(paneId: pane.paneId, as: .guiPeer)

    // Drained between emissions. The pump buffers newest-only, so emitting
    // back to back would let it coalesce and this would be asserting
    // lossless delivery the design doesn't offer (see
    // `rapidDisplayRotationsSettleOnTheNewestValue` for that contract).
    backend.emitDisplayOrientation(.landscapeLeft)
    try await Task.sleep(for: .milliseconds(50))
    // Same value again: the display didn't move, so nothing is published.
    backend.emitDisplayOrientation(.landscapeLeft)
    try await Task.sleep(for: .milliseconds(50))
    backend.emitDisplayOrientation(.portraitUpsideDown)
    try await Task.sleep(for: .milliseconds(50))
    await coordinator.unsubscribe(paneId: pane.paneId, subscriptionId: subscriptionId)

    var orientations: [Orientation] = []
    for await event in stream {
        if case let .orientationChanged(_, orientation) = event { orientations.append(orientation) }
    }
    #expect(orientations == [.portrait, .landscapeLeft, .portraitUpsideDown])
}

@Test
func aCommandedRotationThatMovesTheDisplayPublishesOnce() async throws {
    // A rotation deviceterm commands that *does* move the display arrives
    // back as an observation. Only the observation publishes, so the pane
    // gets one event rather than a command echo plus an observation.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: "disp-echo", sessionId: UUID(), backend: backend)
    let (subscriptionId, stream) = try await coordinator.subscribe(paneId: pane.paneId, as: .guiPeer)

    try await coordinator.rotate(paneId: pane.paneId, as: .guiPeer, target: .absolute(.landscapeLeft))
    backend.emitDisplayOrientation(.landscapeLeft)
    try await Task.sleep(for: .milliseconds(50))
    await coordinator.unsubscribe(paneId: pane.paneId, subscriptionId: subscriptionId)

    var orientations: [Orientation] = []
    for await event in stream {
        if case let .orientationChanged(_, orientation) = event { orientations.append(orientation) }
    }
    #expect(orientations == [.portrait, .landscapeLeft])
}

@Test
func aDisplayWithNoOrientationSourceStillRenders() async throws {
    // A backend that vends no orientation source (a physical device, or a
    // display proxy missing the screen protocol) degrades to the
    // command-sourced fallback: the pane mounts, frames are untouched,
    // and it keeps its assumed orientation. Refusing to observe must never
    // fail the pane.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    backend.displayOrientationAvailable = false
    let pane = try await coordinator.createMockPane(udid: "disp-none", sessionId: UUID(), backend: backend)
    #expect(backend.startDisplayOrientationCalls == 1)
    #expect(backend.startFramesCalled)

    let (subscriptionId, stream) = try await coordinator.subscribe(paneId: pane.paneId, as: .guiPeer)
    await coordinator.unsubscribe(paneId: pane.paneId, subscriptionId: subscriptionId)
    var replayed: [Orientation] = []
    for await event in stream {
        if case let .orientationChanged(_, orientation) = event { replayed.append(orientation) }
    }
    #expect(replayed == [.portrait])
}

@Test
func aPaneWithNoDisplaySourceStillTurnsOnACommand() async throws {
    // The fallback that keeps an unobservable pane working. With no
    // observation coming, the command is the only evidence the pane will
    // ever get, so it publishes and the pane turns. Without this fallback
    // a physical-device pane cannot respond to DeviceTerm rotations; the
    // locked-interface mismatch stays unavoidable without observation.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    backend.displayOrientationAvailable = false
    let pane = try await coordinator.createMockPane(udid: "cmd-fallback", sessionId: UUID(), backend: backend)
    let (subscriptionId, stream) = try await coordinator.subscribe(paneId: pane.paneId, as: .guiPeer)

    try await coordinator.rotate(paneId: pane.paneId, as: .guiPeer, target: .absolute(.landscapeLeft))
    await coordinator.unsubscribe(paneId: pane.paneId, subscriptionId: subscriptionId)

    var orientations: [Orientation] = []
    for await event in stream {
        if case let .orientationChanged(_, orientation) = event { orientations.append(orientation) }
    }
    #expect(orientations == [.portrait, .landscapeLeft])
}

@Test
func aPaneWithNoDisplaySourceStaysPutForAnUnperformedRotation() async throws {
    // The fallback is still gated on the backend performing the rotation.
    // A fenced or failed one publishes nothing, so the pane never turns for
    // a rotation the device didn't make.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend(rotateReaches: false)
    backend.displayOrientationAvailable = false
    let pane = try await coordinator.createMockPane(udid: "cmd-fenced", sessionId: UUID(), backend: backend)
    let (subscriptionId, stream) = try await coordinator.subscribe(paneId: pane.paneId, as: .guiPeer)

    try await coordinator.rotate(paneId: pane.paneId, as: .guiPeer, target: .absolute(.landscapeLeft))
    await coordinator.unsubscribe(paneId: pane.paneId, subscriptionId: subscriptionId)

    var orientations: [Orientation] = []
    for await event in stream {
        if case let .orientationChanged(_, orientation) = event { orientations.append(orientation) }
    }
    #expect(orientations == [.portrait])
}

@Test
func concurrentRotationsCommitTheirBaseInRequestOrder() async throws {
    // Ordering guard: the backend completes rotations serially, but each
    // `rotate` awaits its completion on an independent task. Without
    // coordinator-side serialization a later rotation's continuation could
    // resume first and commit B's base before A's, leaving the tracked base
    // at A while the device ended at B. The rotation chain keeps the
    // commits in request order.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    backend.blockFirstRotate = true
    let pane = try await coordinator.createMockPane(udid: "rot-order", sessionId: UUID(), backend: backend)

    // A: its backend rotate blocks on the gate, holding the rotation chain.
    let first = Task {
        try await coordinator.rotate(paneId: pane.paneId, as: .guiPeer, target: .absolute(.landscapeLeft))
    }
    // Wait until A is parked mid-rotation (A owns the chain tail).
    var waited = 0
    while !backend.firstRotateStarted, waited < 400 {
        try await Task.sleep(for: .milliseconds(5))
        waited += 1
    }
    #expect(backend.firstRotateStarted)

    // B: issued after A holds the chain, so it must await A. Its ungated
    // backend rotate would otherwise complete and commit immediately.
    let second = Task {
        try await coordinator.rotate(paneId: pane.paneId, as: .guiPeer, target: .absolute(.landscapeRight))
    }
    // Give B time to (wrongly) overtake if serialization were broken.
    try await Task.sleep(for: .milliseconds(50))

    backend.releaseFirstRotate()
    try await first.value
    try await second.value
    #expect(backend.rotations == [.landscapeLeft, .landscapeRight])

    // The base the next relative rotate resolves from must be B's target,
    // not A's: one step left of landscapeRight is portrait, where left of
    // landscapeLeft would be portraitUpsideDown.
    try await coordinator.rotate(paneId: pane.paneId, as: .guiPeer, target: .relative(.left))
    #expect(backend.rotations.last == .portrait)
}

@Test
func relativeRotationsWalkTheCycleFromTheTrackedOrientation() async throws {
    // A pane starts tracking `.portrait`, so four Rotate Lefts must reach
    // four distinct orientations and wrap, rather than re-sending the same
    // target because the base never advanced.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: "rot-rel", sessionId: UUID(), backend: backend)
    for _ in 0..<4 {
        try await coordinator.rotate(paneId: pane.paneId, as: .guiPeer, target: .relative(.left))
    }
    #expect(backend.rotations == [
        .landscapeLeft,
        .portraitUpsideDown,
        .landscapeRight,
        .portrait
    ])
}

@Test
func relativeRotationResolvesFromThePrecedingAbsoluteOne() async throws {
    // Absolute and relative write and read the same tracked value, so a
    // direction after an absolute rotate steps from where that rotate put
    // the device, not from the pane's boot orientation.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: "rot-mix", sessionId: UUID(), backend: backend)
    try await coordinator.rotate(paneId: pane.paneId, as: .guiPeer, target: .absolute(.landscapeRight))
    try await coordinator.rotate(paneId: pane.paneId, as: .guiPeer, target: .relative(.right))
    #expect(backend.rotations == [.landscapeRight, .portraitUpsideDown])
}

@Test
func aRotationTheDeviceDidNotMakeLeavesTheBaseUnchanged() async throws {
    // `rotateReaches: false` is a fenced or failed rotation. The tracked
    // orientation must not move for one, or the error compounds: every
    // later relative request resolves from a place the device never
    // reached.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend(rotateReaches: false)
    let pane = try await coordinator.createMockPane(udid: "rot-miss", sessionId: UUID(), backend: backend)
    try await coordinator.rotate(paneId: pane.paneId, as: .guiPeer, target: .relative(.left))
    try await coordinator.rotate(paneId: pane.paneId, as: .guiPeer, target: .relative(.left))
    #expect(backend.rotations == [.landscapeLeft, .landscapeLeft])
}

@Test
func concurrentRelativeRotationsEachAdvanceOneStep() async throws {
    // The reason a direction resolves *inside* the rotation chain rather
    // than before it. Both requests are in flight at once; if the second
    // read the tracked orientation before awaiting the first, both would
    // pick `landscapeLeft` and one 90° step would silently vanish.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    backend.blockFirstRotate = true
    let pane = try await coordinator.createMockPane(udid: "rot-race", sessionId: UUID(), backend: backend)

    let first = Task {
        try await coordinator.rotate(paneId: pane.paneId, as: .guiPeer, target: .relative(.left))
    }
    var waited = 0
    while !backend.firstRotateStarted, waited < 400 {
        try await Task.sleep(for: .milliseconds(5))
        waited += 1
    }
    #expect(backend.firstRotateStarted)

    let second = Task {
        try await coordinator.rotate(paneId: pane.paneId, as: .guiPeer, target: .relative(.left))
    }
    // Give the second request time to (wrongly) resolve off the stale base.
    try await Task.sleep(for: .milliseconds(50))
    backend.releaseFirstRotate()
    try await first.value
    try await second.value

    #expect(backend.rotations == [.landscapeLeft, .portraitUpsideDown])
}

@Test
func subscribeReplaysTheDisplaysOrientation() async throws {
    // A subscriber that arrives after the display turned has to be told
    // what it is showing. Without the replay it renders and hit-tests a
    // landscape display as portrait until something turns it again, which
    // is what a GUI relaunching onto a still-running pane would do.
    //
    // It replays what the display is presenting, not what was last
    // commanded, so it matches the pixels in the next frame.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: "rot-replay", sessionId: UUID(), backend: backend)
    backend.emitDisplayOrientation(.landscapeRight)
    try await Task.sleep(for: .milliseconds(50))

    let (subscriptionId, stream) = try await coordinator.subscribe(paneId: pane.paneId, as: .guiPeer)
    await coordinator.unsubscribe(paneId: pane.paneId, subscriptionId: subscriptionId)
    var replayed: [Orientation] = []
    for await event in stream {
        if case let .orientationChanged(_, orientation) = event { replayed.append(orientation) }
    }
    #expect(replayed == [.landscapeRight])
}

@Test
func attachSeedsTheDisplayOrientationBeforeAnySubscriber() async throws {
    // Mounting a pane onto a device whose display is already landscape has
    // to start correct: the seed is read at attach, so the first subscriber
    // is replayed landscape without waiting for a change that may never
    // come.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    backend.displayOrientation = .landscapeLeft
    let pane = try await coordinator.createMockPane(udid: "rot-seed", sessionId: UUID(), backend: backend)

    let (subscriptionId, stream) = try await coordinator.subscribe(paneId: pane.paneId, as: .guiPeer)
    await coordinator.unsubscribe(paneId: pane.paneId, subscriptionId: subscriptionId)
    var replayed: [Orientation] = []
    for await event in stream {
        if case let .orientationChanged(_, orientation) = event { replayed.append(orientation) }
    }
    #expect(replayed == [.landscapeLeft])
}

@Test
func anExternalRotationLeavesTheCommandBaseAlone() async throws {
    // Display state is the foreground app's interface
    // orientation, so it must not correct the command base: a portrait
    // device running a landscape-locked app would otherwise drive the base
    // to landscape and mis-target the next relative rotate.
    //
    // The cost of that choice is this: after an out-of-band rotation the
    // base is stale, so exactly one relative rotate goes to the wrong
    // place. It self-corrects immediately, because rotate is absolute at
    // every layer.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: "rot-external", sessionId: UUID(), backend: backend)

    // Something outside deviceterm turns the device to landscapeLeft.
    backend.emitDisplayOrientation(.landscapeLeft)
    try await Task.sleep(for: .milliseconds(50))

    // The base is still the assumed portrait, so this resolves from there.
    try await coordinator.rotate(paneId: pane.paneId, as: .guiPeer, target: .relative(.left))
    #expect(backend.rotations == [.landscapeLeft])
    // And now the base is true again: the command made it so.
    try await coordinator.rotate(paneId: pane.paneId, as: .guiPeer, target: .relative(.left))
    #expect(backend.rotations.last == .portraitUpsideDown)
}

@Test
func aDisplayCallbackInFlightPastTeardownIsDropped() async throws {
    // Unregistering can't recall a block already dispatched on the
    // callback queue, so a late delivery is expected rather than
    // hypothetical. Fenced on `displayObserverEpoch`, so a delivery
    // arriving after orientation teardown can't update a retired record
    // that is still present.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: "rot-late", sessionId: UUID(), backend: backend)
    let (subscriptionId, stream) = try await coordinator.subscribe(paneId: pane.paneId, as: .guiPeer)
    let late = try #require(backend.installedCallback)

    // Retire the pane, which bumps the epoch the observer captured.
    await coordinator.markPaneFailed(paneId: pane.paneId, reason: "test")
    // Now deliver the observation that was already in flight.
    late(.landscapeRight)
    try await Task.sleep(for: .milliseconds(50))
    await coordinator.unsubscribe(paneId: pane.paneId, subscriptionId: subscriptionId)

    var orientations: [Orientation] = []
    for await event in stream {
        if case let .orientationChanged(_, orientation) = event { orientations.append(orientation) }
    }
    // Only the subscribe-time replay; the late delivery published nothing.
    #expect(orientations == [.portrait])
}

@Test
func orientationObservationSurvivesAnOwnershipEpochBump() async throws {
    // The pane's `epoch` also advances on owner revocation and on both
    // halves of an ownership transfer, none of which stop the observer or
    // change what the display is doing. Fencing observation on it would
    // leave a live observer whose every delivery is rejected, and because
    // the command fallback stands down while observation is running, the
    // pane's orientation would freeze permanently the first time it changed
    // hands. The observer has its own epoch for exactly this reason.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let sessionId = UUID()
    let pane = try await coordinator.createMockPane(udid: "rot-epoch", sessionId: sessionId, backend: backend)
    let (subscriptionId, stream) = try await coordinator.subscribe(paneId: pane.paneId, as: .guiPeer)

    // Revoke the owning session, which bumps the pane's `epoch`. The
    // `.guiPeer` subscription is spared, so the stream stays open.
    await coordinator.revokeSubscriptions(forSession: sessionId)

    backend.emitDisplayOrientation(.landscapeRight)
    try await Task.sleep(for: .milliseconds(50))
    await coordinator.unsubscribe(paneId: pane.paneId, subscriptionId: subscriptionId)

    var orientations: [Orientation] = []
    for await event in stream {
        if case let .orientationChanged(_, orientation) = event { orientations.append(orientation) }
    }
    #expect(orientations == [.portrait, .landscapeRight])
}

@Test
func rapidDisplayRotationsSettleOnTheNewestValue() async throws {
    // Deliveries ride an ordered pump rather than one unstructured task
    // each, because independent tasks have no ordering guarantee and a
    // reversed pair would leave the pane on the older orientation for good.
    // Whatever intermediates get coalesced, the value the pane ends on is
    // the one the display last reported.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: "rot-burst", sessionId: UUID(), backend: backend)
    let (subscriptionId, stream) = try await coordinator.subscribe(paneId: pane.paneId, as: .guiPeer)

    backend.emitDisplayOrientation(.landscapeLeft)
    backend.emitDisplayOrientation(.portraitUpsideDown)
    backend.emitDisplayOrientation(.landscapeRight)
    try await Task.sleep(for: .milliseconds(100))
    await coordinator.unsubscribe(paneId: pane.paneId, subscriptionId: subscriptionId)

    var orientations: [Orientation] = []
    for await event in stream {
        if case let .orientationChanged(_, orientation) = event { orientations.append(orientation) }
    }
    #expect(orientations.last == .landscapeRight)
}

@Test
func retiringAPaneStopsObservingTheDisplay() async throws {
    // The observer is owned by the pane record, so it stops when the pane
    // does. A callback that outlived teardown would resurrect orientation
    // state on a pane that no longer exists.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let sessionId = UUID()
    let pane = try await coordinator.createMockPane(udid: "rot-teardown", sessionId: sessionId, backend: backend)
    #expect(backend.startDisplayOrientationCalls == 1)

    _ = await coordinator.close(paneId: pane.paneId, as: .session(sessionId), mode: .detach)
    #expect(backend.stopDisplayOrientationCalls == 1)
}

@Test
func subscribeReplaysPortraitForAPaneNothingHasRotated() async throws {
    // The replay is unconditional so a subscriber always has an orientation
    // to start from, rather than inferring one from the event's absence.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(udid: "rot-fresh", sessionId: UUID(), backend: backend)

    let (subscriptionId, stream) = try await coordinator.subscribe(paneId: pane.paneId, as: .guiPeer)
    await coordinator.unsubscribe(paneId: pane.paneId, subscriptionId: subscriptionId)
    var replayed: [Orientation] = []
    for await event in stream {
        if case let .orientationChanged(_, orientation) = event { replayed.append(orientation) }
    }
    #expect(replayed == [.portrait])
}

@Test
func verbUnsupportedByBackendThrowsUnsupportedOperation() async throws {
    let coordinator = PaneCoordinator()
    // A backend that supports touch but not crown, like a physical
    // device pane will.
    // `.withoutLocation` because the mock takes the protocol's throwing
    // location defaults; only `crown` is the subject here.
    var caps = DeviceBackendCapabilities.simulator.withoutLocation
    caps.crown = false
    let backend = MockDeviceBackend(capabilities: caps)
    let result = try await coordinator.createMockPane(udid: "udid-c", sessionId: UUID(), backend: backend)
    await #expect(throws: PaneError.unsupportedOperation(paneId: result.paneId, operation: .crown)) {
        try await coordinator.crown(paneId: result.paneId, as: .guiPeer, delta: 1.0, durationMs: 0)
    }
    // Touch still works on the same pane.
    try await coordinator.tap(paneId: result.paneId, as: .guiPeer, x: 0.5, y: 0.5)
    #expect(backend.tapDownPoints.count == 1)
    #expect(backend.crownDeltas.isEmpty)
}

@Test
func sameSessionRecreateIsIdempotent() async throws {
    let coordinator = PaneCoordinator()
    let session = UUID()
    let first = try await coordinator.createMockPane(udid: "udid-d", sessionId: session, backend: MockDeviceBackend())
    // Second create for the same target + session returns the existing
    // pane rather than cutting a duplicate; the second backend is never
    // started.
    let secondBackend = MockDeviceBackend()
    let second = try await coordinator.createMockPane(udid: "udid-d", sessionId: session, backend: secondBackend)
    #expect(first.paneId == second.paneId)
    #expect(!secondBackend.startFramesCalled)
    let panes = await coordinator.panesForSession(session)
    #expect(panes.count == 1)
}

@Test
func aReAdmissionInvalidatesTheEarlierAttachmentForClose() async throws {
    // The close fence. A same-owner re-attach that re-admits the record hands
    // the caller a NEW `attachment`, and a close still carrying the previous
    // one is refused: dispatch is non-FIFO, so a close sent before the
    // re-attach can arrive after it, and retiring the record then would take
    // the pane away from the caller that just re-attached.
    let coordinator = PaneCoordinator()
    let session = UUID()
    let first = try await coordinator.createMockPane(
        udid: "udid-fence",
        sessionId: session,
        backend: MockDeviceBackend(),
        revision: 1
    )
    let second = try await coordinator.createMockPane(
        udid: "udid-fence",
        sessionId: session,
        backend: MockDeviceBackend(),
        revision: 2
    )
    #expect(first.paneId == second.paneId)
    #expect(first.attachment != second.attachment)

    _ = await coordinator.close(
        paneId: first.paneId,
        as: .guiPeer,
        mode: .detach,
        expecting: first.attachment
    )
    #expect(await coordinator.panesForSession(session).count == 1)

    _ = await coordinator.close(
        paneId: second.paneId,
        as: .guiPeer,
        mode: .detach,
        expecting: second.attachment
    )
    #expect(await coordinator.panesForSession(session).isEmpty)
}

@Test
func anUnfencedCloseStillRetiresThePane() async throws {
    // A caller with no admission to name (the CLI's `pane close`) omits the
    // value and closes unconditionally.
    let coordinator = PaneCoordinator()
    let session = UUID()
    let pane = try await coordinator.createMockPane(
        udid: "udid-unfenced",
        sessionId: session,
        backend: MockDeviceBackend()
    )
    _ = await coordinator.close(paneId: pane.paneId, as: .guiPeer, mode: .detach)
    #expect(await coordinator.panesForSession(session).isEmpty)
}

@Test
func anAdoptionInvalidatesThePriorOwnersAttachment() async throws {
    // The transfer half of the same rule: an adoption is a new admission, so
    // the dead owner's close can't retire the record the adopter now holds.
    let coordinator = PaneCoordinator()
    let owner = UUID()
    let adopter = UUID()
    let original = try await coordinator.createMockPane(
        udid: "udid-adopt-fence",
        sessionId: owner,
        backend: MockDeviceBackend()
    )
    let adopted = try await coordinator.createMockPane(
        udid: "udid-adopt-fence",
        sessionId: adopter,
        backend: MockDeviceBackend(),
        isOwnerSessionAlive: { _ in false }
    )
    #expect(original.paneId == adopted.paneId)
    #expect(original.attachment != adopted.attachment)
    _ = await coordinator.close(
        paneId: original.paneId,
        as: .guiPeer,
        mode: .detach,
        expecting: original.attachment
    )
    #expect(await coordinator.panesForSession(adopter).count == 1)
}

@Test
func anUnrevisionedReAttachLeavesTheHoldersTokenWorking() async throws {
    // A CLI attach (no revision) inside a tab that already shows the sim is
    // the ordinary case, not an exotic one: the shim auto-attaches on every
    // command run there. It returns the same record, so it must not re-admit
    // it. Advancing would retire the GUI's token without telling the GUI, and
    // its next close would be refused with the pane and its backend left
    // running.
    let coordinator = PaneCoordinator()
    let session = UUID()
    let held = try await coordinator.createMockPane(
        udid: "udid-idempotent",
        sessionId: session,
        backend: MockDeviceBackend(),
        revision: 1
    )
    let unrevisioned = try await coordinator.createMockPane(
        udid: "udid-idempotent",
        sessionId: session,
        backend: MockDeviceBackend()
    )
    #expect(unrevisioned.paneId == held.paneId)
    #expect(unrevisioned.attachment == held.attachment)

    // The token the first caller is still holding continues to close it.
    _ = await coordinator.close(
        paneId: held.paneId,
        as: .guiPeer,
        mode: .detach,
        expecting: held.attachment
    )
    #expect(await coordinator.panesForSession(session).isEmpty)
}

@Test
func anUnrevisionedReAttachDoesNotClearTheRevisionSeries() async throws {
    // The series survives an unrevisioned re-attach, so a stale revisioned
    // one arriving afterwards is still refused. Resetting it to nil would
    // reopen exactly the reordering the series exists to catch.
    let coordinator = PaneCoordinator()
    let session = UUID()
    _ = try await coordinator.createMockPane(
        udid: "udid-series",
        sessionId: session,
        backend: MockDeviceBackend(),
        revision: 2
    )
    let current = try await coordinator.createMockPane(
        udid: "udid-series",
        sessionId: session,
        backend: MockDeviceBackend()
    )
    await #expect(throws: PaneError.staleAttach(paneId: current.paneId)) {
        try await coordinator.createMockPane(
            udid: "udid-series",
            sessionId: session,
            backend: MockDeviceBackend(),
            revision: 1
        )
    }
}

@Test
func aSupersededReAttachIsRefusedRatherThanReAdmitting() async throws {
    // The ordering the response alone can't supply. Two of one caller's
    // attaches are in flight (a timed-out one and its retry); the daemon may
    // handle them in either order. If the older one were admitted second it
    // would move the record to an `attachment` that caller never receives,
    // and every close it sends afterwards would be silently refused while it
    // dropped the pane from its own state, leaking the backend.
    let coordinator = PaneCoordinator()
    let session = UUID()
    _ = try await coordinator.createMockPane(
        udid: "udid-stale",
        sessionId: session,
        backend: MockDeviceBackend()
    )
    let newer = try await coordinator.createMockPane(
        udid: "udid-stale",
        sessionId: session,
        backend: MockDeviceBackend(),
        revision: 2
    )
    await #expect(throws: PaneError.staleAttach(paneId: newer.paneId)) {
        try await coordinator.createMockPane(
            udid: "udid-stale",
            sessionId: session,
            backend: MockDeviceBackend(),
            revision: 1
        )
    }
    // The refused attach changed nothing, so the caller's close still lands.
    _ = await coordinator.close(
        paneId: newer.paneId,
        as: .guiPeer,
        mode: .detach,
        expecting: newer.attachment
    )
    #expect(await coordinator.panesForSession(session).isEmpty)
}

@Test
func anAdvancingRevisionStillReAdmits() async throws {
    // The ordinary case the staleness gate must not break: each re-attach
    // carries a higher revision than the last, so every one is admitted and
    // hands back a fresh attachment.
    let coordinator = PaneCoordinator()
    let session = UUID()
    let first = try await coordinator.createMockPane(
        udid: "udid-advance",
        sessionId: session,
        backend: MockDeviceBackend(),
        revision: 1
    )
    let second = try await coordinator.createMockPane(
        udid: "udid-advance",
        sessionId: session,
        backend: MockDeviceBackend(),
        revision: 2
    )
    #expect(first.paneId == second.paneId)
    #expect(second.attachment > first.attachment)
}

@Test
func crossSessionLiveOwnerIsRejected() async throws {
    let coordinator = PaneCoordinator()
    let owner = UUID()
    let intruder = UUID()
    _ = try await coordinator.createMockPane(udid: "udid-e", sessionId: owner, backend: MockDeviceBackend())
    // Prior owner reported alive → a different session cannot steal it.
    await #expect(throws: PaneError.paneAlreadyAttached(udid: "udid-e", ownerSessionId: owner)) {
        try await coordinator.createMockPane(
            udid: "udid-e",
            sessionId: intruder,
            backend: MockDeviceBackend(),
            isOwnerSessionAlive: { _ in true }
        )
    }
}

@Test
func inFlightGestureSurvivesConcurrentClose() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let result = try await coordinator.createMockPane(udid: "udid-g", sessionId: UUID(), backend: backend)
    // Start a multi-step swipe; it yields at each inter-step sleep, so
    // the close below runs on the actor mid-gesture.
    async let gesture: Void = {
        _ = try await coordinator.swipe(
            paneId: result.paneId,
            as: .guiPeer,
            fromX: 0,
            fromY: 0,
            toX: 1,
            toY: 1,
            durationMs: 300
        )
    }()
    // Let the swipe reach its first await (past the initial tapDown), then
    // close the pane while the swipe still holds contact.
    try await Task.sleep(nanoseconds: 20_000_000)
    let closed = await coordinator.close(paneId: result.paneId, as: .guiPeer, mode: .detach)
    // The swipe still held the pane's contact, so the close retired the pane
    // and postponed its teardown rather than niling the backend mid-gesture.
    let deferral = try #require(closed.deferral)
    #expect(!backend.shutdownCalled)
    // The gesture must complete: it drives the backend it captured at
    // the start, not a per-step re-lookup that would now find no pane.
    try await gesture
    await coordinator.awaitDeferredTeardown(deferral)
    #expect(backend.shutdownCalled)
    #expect(backend.tapDownPoints.count >= 2)
    #expect(backend.tapUpPoints.count == 1)
}

@Test
func swipeWithHoldActivelyDwellsAtEndBeforeLift() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let result = try await coordinator.createMockPane(
        udid: "udid-hold",
        sessionId: UUID(),
        backend: backend
    )
    let end = CGPoint(x: 1, y: 1)
    // duration 32 → 2 move steps (the 2nd lands on `end`); hold 99 → 3
    // active dwell frames (~33ms cadence) re-reporting contact at `end`,
    // then a single lift. The dwell is *reported* tapDowns, not a passive
    // sleep, and each frame is nudged a sub-pixel off `end` so the
    // synchronous sim HID send doesn't stall on an identical resend.
    _ = try await coordinator.swipe(
        paneId: result.paneId,
        as: .guiPeer,
        fromX: 0,
        fromY: 0,
        toX: 1,
        toY: 1,
        durationMs: 32,
        holdMs: 99
    )
    // 1 initial down (origin) + 2 move steps + 3 dwell frames.
    #expect(backend.tapDownPoints.count == 6)
    // The dwell frames sit at the end point's row, within a sub-pixel on
    // x: the "finger held still while down" signature.
    let dwell = backend.tapDownPoints.suffix(3)
    #expect(dwell.allSatisfy { abs($0.x - end.x) <= 0.0015 && $0.y == end.y })
    // None of the dwell frames is an exact identical resend of `end`.
    #expect(dwell.allSatisfy { $0 != end })
    #expect(backend.tapUpPoints == [end])
}

@Test
func edgeSwipeEmitsEdgeTaggedDownDragUp() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let result = try await coordinator.createMockPane(
        udid: "udid-edge",
        sessionId: UUID(),
        backend: backend
    )
    // duration 32 → 2 drag samples; hold 0 → no dwell.
    try await coordinator.edgeSwipe(
        paneId: result.paneId,
        as: .guiPeer,
        fromX: 0.5,
        fromY: 0.99,
        toX: 0.5,
        toY: 0.5,
        edge: 3,
        durationMs: 32,
        holdMs: 0
    )
    // down (origin) + 2 drag samples, all edge-tagged with the bottom
    // edge; a single edge-tagged lift at the end.
    #expect(backend.edgeDownPoints.count == 1)
    #expect(backend.edgeMovePoints.count == 2)
    #expect(backend.edgeUpPoints.count == 1)
    #expect(backend.edgeValues.allSatisfy { $0 == 3 })
    // Plain touch path is untouched.
    #expect(backend.tapDownPoints.isEmpty)
}

@Test("App Switcher on a device backend fires a system-gesture swipe")
func edgeSwipeOnDeviceBackendUsesSystemSwipe() async throws {
    let coordinator = PaneCoordinator()
    // A physical-device-like backend: can't route a system edge swipe, but
    // implements the system-gesture App Switcher swipe.
    let backend = MockDeviceBackend(edgeUnsupported: true)
    let result = try await coordinator.createMockPane(
        udid: "udid-device-appswitcher",
        sessionId: UUID(),
        backend: backend
    )
    try await coordinator.edgeSwipe(
        paneId: result.paneId,
        as: .guiPeer,
        fromX: 0.5,
        fromY: 0.99,
        toX: 0.5,
        toY: 0.5,
        edge: 3,
        durationMs: 32,
        holdMs: 0
    )
    // The swipe coordinates are ignored; the App Switcher is realized as one
    // system-gesture swipe. No edge-touch primitive and no button press.
    #expect(backend.openAppSwitcherCalls == 1)
    // The originating edge is forwarded so the device swipe rotates with the
    // pane's orientation (here portrait = 3).
    #expect(backend.openAppSwitcherEdges == [3])
    #expect(backend.buttons.isEmpty)
    #expect(backend.edgeDownPoints.isEmpty)
    #expect(backend.edgeMovePoints.isEmpty)
}

@Test("App Switcher on a device forwards the landscape edge")
func edgeSwipeOnDeviceForwardsLandscapeEdge() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend(edgeUnsupported: true)
    let result = try await coordinator.createMockPane(
        udid: "udid-device-appswitcher-landscape",
        sessionId: UUID(),
        backend: backend
    )
    // landscapeLeft's IndigoHIDEdge value: the device maps it to its native
    // left edge so the swipe (and the report trailer) rotate with the device.
    let landscapeEdge = try #require(AppSwitcherGesture.edge(for: .landscapeLeft))
    try await coordinator.edgeSwipe(
        paneId: result.paneId,
        as: .guiPeer,
        fromX: 0.01,
        fromY: 0.5,
        toX: 0.5,
        toY: 0.5,
        edge: landscapeEdge,
        durationMs: 32,
        holdMs: 0
    )
    #expect(backend.openAppSwitcherEdges == [landscapeEdge])
}

@Test("App Switcher falls back to a Home double-press without the swipe")
func edgeSwipeFallsBackToDoublePressWithoutSystemSwipe() async throws {
    let coordinator = PaneCoordinator()
    // A device-like backend that doesn't implement the swipe (openAppSwitcher
    // throws `unsupportedEdgeGesture`) must fall back to the Home double-press.
    let backend = MockDeviceBackend(edgeUnsupported: true, appSwitcherUnsupported: true)
    let result = try await coordinator.createMockPane(
        udid: "udid-device-fallback",
        sessionId: UUID(),
        backend: backend
    )
    try await coordinator.edgeSwipe(
        paneId: result.paneId,
        as: .guiPeer,
        fromX: 0.5,
        fromY: 0.99,
        toX: 0.5,
        toY: 0.5,
        edge: 3,
        durationMs: 32,
        holdMs: 0
    )
    #expect(backend.buttons == [.home, .home])
    #expect(backend.openAppSwitcherCalls == 0)
    #expect(backend.edgeDownPoints.isEmpty)
    #expect(backend.edgeMovePoints.isEmpty)
}

@Test("edgeTouch maps each phase to its own edge primitive")
func edgeTouchMapsPhasesToEdgePrimitives() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let result = try await coordinator.createMockPane(
        udid: "udid-edgetouch",
        sessionId: UUID(),
        backend: backend
    )
    try await coordinator.edgeTouch(paneId: result.paneId, as: .guiPeer, x: 0.5, y: 0.99, phase: .down, edge: 3)
    try await coordinator.edgeTouch(paneId: result.paneId, as: .guiPeer, x: 0.5, y: 0.80, phase: .move, edge: 3)
    try await coordinator.edgeTouch(paneId: result.paneId, as: .guiPeer, x: 0.5, y: 0.50, phase: .lift, edge: 3)
    // Distinct primitive per phase: the per-phase NSEventType is what
    // the system recognizer needs (unlike plain `touch`, which collapses
    // down/move to `tapDown`).
    #expect(backend.edgeDownPoints == [CGPoint(x: 0.5, y: 0.99)])
    #expect(backend.edgeMovePoints == [CGPoint(x: 0.5, y: 0.80)])
    #expect(backend.edgeUpPoints == [CGPoint(x: 0.5, y: 0.50)])
    #expect(backend.edgeValues == [3, 3, 3])
    // The plain-touch primitives stay untouched.
    #expect(backend.tapDownPoints.isEmpty)
    #expect(backend.tapUpPoints.isEmpty)
}

@Test("a locked interface takes the rotate but the pane does not turn")
func lockedInterfaceTakesRotateWithoutTurningThePane() async throws {
    // The rotate reaches the
    // device, so the command is real; the display never moves, because the
    // foreground app holds its interface orientation. The pane must stay
    // where it is: it is still showing a portrait framebuffer, and turning
    // it would counter-rotate that framebuffer on screen.
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let result = try await coordinator.createMockPane(
        udid: "udid-rot",
        sessionId: UUID(),
        backend: backend
    )
    let (subscriptionId, stream) = try await coordinator.subscribe(paneId: result.paneId, as: .guiPeer)
    try await coordinator.rotate(paneId: result.paneId, as: .guiPeer, target: .absolute(.landscapeLeft))
    // Unsubscribe finishes the stream so the drain terminates instead of
    // blocking on an open subscription (and so a regression fails as a
    // missing event, not a hang).
    await coordinator.unsubscribe(paneId: result.paneId, subscriptionId: subscriptionId)
    var orientations: [Orientation] = []
    for await event in stream {
        if case let .orientationChanged(_, orientation) = event {
            orientations.append(orientation)
        }
    }
    // Only the subscribe-time replay. The rotate published nothing.
    #expect(orientations == [.portrait])
    #expect(backend.rotations == [.landscapeLeft])
}

@Test("edgeTouch on a device backend surfaces unsupportedOperation")
func edgeTouchUnsupportedOnDeviceBackend() async throws {
    let coordinator = PaneCoordinator()
    // A device-style backend: touch-capable but no edge-gesture path.
    // Its `edgeTouchDown` throws `unsupportedEdgeGesture`.
    let backend = MockDeviceBackend(edgeUnsupported: true)
    let result = try await coordinator.createMockPane(
        udid: "udid-edge-dev",
        sessionId: UUID(),
        backend: backend
    )
    var thrown: PaneError?
    do {
        try await coordinator.edgeTouch(paneId: result.paneId, as: .guiPeer, x: 0.5, y: 0.99, phase: .down, edge: 3)
    } catch let error as PaneError {
        thrown = error
    }
    guard case .unsupportedOperation(_, let operation)? = thrown else {
        Issue.record("expected unsupportedOperation, got \(String(describing: thrown))")
        return
    }
    // The wire names the verb the caller actually invoked, not a sibling.
    #expect(operation == .edgeTouch)
}

@Test
func swipeWithStartHoldGrabsAtOriginBeforeMoving() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let result = try await coordinator.createMockPane(
        udid: "udid-start-hold",
        sessionId: UUID(),
        backend: backend
    )
    // startHold 99 → 3 active grab frames at the origin (before any
    // motion); duration 32 → 2 move steps; no end hold.
    _ = try await coordinator.swipe(
        paneId: result.paneId,
        as: .guiPeer,
        fromX: 0,
        fromY: 0,
        toX: 1,
        toY: 1,
        durationMs: 32,
        holdMs: 0,
        startHoldMs: 99
    )
    // 1 initial down + 3 grab frames + 2 move steps.
    #expect(backend.tapDownPoints.count == 6)
    // The grab (origin down + 3 dwell frames) sits on the origin row,
    // within a sub-pixel on x: the "grab the handle" before dragging.
    let grab = backend.tapDownPoints.prefix(4)
    #expect(grab.allSatisfy { abs($0.x) <= 0.0015 && $0.y == 0 })
    #expect(backend.tapUpPoints == [CGPoint(x: 1, y: 1)])
}

@Test
func swipeWithZeroHoldIsByteIdenticalToPlainSwipe() async throws {
    // The default `holdMs` (0) must leave the no-dwell wire exactly as
    // it was before the hold parameter existed.
    let held = PaneCoordinator()
    let heldBackend = MockDeviceBackend()
    let heldPane = try await held.createMockPane(
        udid: "u-zero-hold",
        sessionId: UUID(),
        backend: heldBackend
    )
    _ = try await held.swipe(
        paneId: heldPane.paneId,
        as: .guiPeer,
        fromX: 0,
        fromY: 0,
        toX: 1,
        toY: 1,
        durationMs: 48,
        holdMs: 0
    )

    let plain = PaneCoordinator()
    let plainBackend = MockDeviceBackend()
    let plainPane = try await plain.createMockPane(
        udid: "u-plain",
        sessionId: UUID(),
        backend: plainBackend
    )
    _ = try await plain.swipe(
        paneId: plainPane.paneId,
        as: .guiPeer,
        fromX: 0,
        fromY: 0,
        toX: 1,
        toY: 1,
        durationMs: 48
    )

    #expect(heldBackend.tapDownPoints == plainBackend.tapDownPoints)
    #expect(heldBackend.tapUpPoints == plainBackend.tapUpPoints)
}

@Test
func crossSessionDeadOwnerIsAdopted() async throws {
    let coordinator = PaneCoordinator()
    let owner = UUID()
    let recovery = UUID()
    let original = try await coordinator.createMockPane(udid: "udid-f", sessionId: owner, backend: MockDeviceBackend())
    // Prior owner reported dead → the orphan pane is adopted into the
    // new session, same paneId, no re-acquire.
    let adopted = try await coordinator.createMockPane(
        udid: "udid-f",
        sessionId: recovery,
        backend: MockDeviceBackend(),
        isOwnerSessionAlive: { _ in false }
    )
    #expect(original.paneId == adopted.paneId)
    let ownerPanes = await coordinator.panesForSession(owner)
    let recoveryPanes = await coordinator.panesForSession(recovery)
    #expect(ownerPanes.isEmpty)
    #expect(recoveryPanes.count == 1)
}

// MARK: - Ordered publish pump

/// Mint a small throwaway retained surface for driving the publish pump.
private func makeTestSurface() throws -> RetainedSurface {
    RetainedSurface(try #require(SurfaceCopy.makeSurface(width: 4, height: 4)))
}

/// Wrap a throwaway surface as an unleased (sim-style) published frame.
private func makeTestPublished() throws -> PublishedSurface {
    PublishedSurface(owned: LeasedSurface(surface: try makeTestSurface()), lease: nil)
}

/// Weak handle to a pushed surface, so a test can observe whether the
/// pump released it rather than retaining a per-frame backlog.
private final class WeakSurfaceBox {
    weak var surface: RetainedSurface?
    init(_ surface: RetainedSurface) { self.surface = surface }
}

/// Result carrier for the parked-consumer test. The write (on the pusher
/// thread) happens-before the read (on the awaiting task) via the
/// `tapDown` release semaphore, so `@unchecked Sendable` is sound.
private final class SurfaceCountBox: @unchecked Sendable {
    var pushed = 0
    var alive = 0
}

@Test("serial pump bounds retention while the consumer is parked")
func serialPumpBoundsRetentionWhileConsumerParked() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    backend.blockTapDown = true
    let result = try await coordinator.createMockPane(
        udid: "udid-pump-parked",
        sessionId: UUID(),
        backend: backend
    )
    let onSurface = try #require(backend.onSurface)

    // Parking the coordinator actor means blocking one cooperative thread
    // inside `tapDown`. So the code that detects the park, pushes frames,
    // measures, and RELEASES the block runs on a dedicated non-cooperative
    // `Thread`, never the cooperative pool. That guarantees the signaler
    // can always make progress even on a single-thread executor, so this
    // can't deadlock. Frames are pushed only after the actor is provably
    // parked, so it's deterministic, not a speed race.
    let counts = SurfaceCountBox()
    Thread.detachNewThread {
        while !backend.tapDownParked { Thread.sleep(forTimeInterval: 0.0005) }
        // Push a burst, keeping only weak references. `.bufferingNewest(1)`
        // retains exactly one unpulled frame; the stalled serial pump
        // holds at most one more. A per-frame-Task pump would instead
        // queue a Task per frame on the held actor, each retaining its
        // surface, keeping every pushed frame alive.
        var boxes: [WeakSurfaceBox] = []
        for _ in 0..<256 {
            guard let raw = SurfaceCopy.makeSurface(width: 4, height: 4) else { continue }
            let surface = RetainedSurface(raw)
            boxes.append(WeakSurfaceBox(surface))
            onSurface(PublishedSurface(owned: LeasedSurface(surface: surface), lease: nil))
        }
        counts.pushed = boxes.count
        counts.alive = boxes.filter { $0.surface != nil }.count
        // Release the actor only after measuring, so the pump was provably
        // parked for the whole burst.
        backend.releaseTapDown()
    }

    // Hold the actor: `tapDown` parks until the pusher releases it. This
    // `await` suspends the task (holding no thread) while the
    // actor-isolated consumer can't run.
    _ = try? await coordinator.tap(paneId: result.paneId, as: .guiPeer, x: 0.5, y: 0.5)

    #expect(counts.pushed > 0)
    #expect(counts.alive <= 2)
    _ = await coordinator.close(paneId: result.paneId, as: .guiPeer, mode: .detach)
}

@Test("ordered pump delivers every frame in order when the consumer keeps up")
func orderedPumpDeliversEveryFrameWhenPaced() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let result = try await coordinator.createMockPane(
        udid: "udid-pump-paced",
        sessionId: UUID(),
        backend: backend
    )
    let onSurface = try #require(backend.onSurface)
    let (subscriptionId, stream) = try await coordinator.subscribe(paneId: result.paneId, as: .guiPeer)
    var iterator = stream.makeAsyncIterator()

    // Pace one frame per delivery: only one frame is ever in flight, so
    // `.bufferingNewest(1)` never drops and each frame's sequence is its
    // ordinal: proving the pump preserves order and doesn't spuriously
    // drop when it can keep up.
    let count: UInt64 = 8
    for expected in 1...count {
        onSurface(try makeTestPublished())
        while let event = await iterator.next() {
            if case let .surfaceChanged(_, sequence) = event {
                #expect(sequence == expected)
                break
            }
        }
    }

    await coordinator.unsubscribe(paneId: result.paneId, subscriptionId: subscriptionId)
}

@Test
func liveOwnerSessionIdsExcludesTerminalPanes() async throws {
    // The daemon's stay-alive predicate keeps the daemon up while a
    // non-terminal pane's owner GUI is alive. A shutdown *notification* (a
    // shim/menu shutdown via `markPanesShutdown`) leaves a lingering
    // `.shutdown` record but drops its owner from the live set, so it can't
    // pin the daemon on a dead mirror. (A GUI `close` instead removes the
    // record outright: see `closeRemovesAnExistingPaneRecord`.)
    let coordinator = PaneCoordinator()
    let sessionA = UUID()
    let sessionB = UUID()
    _ = try await coordinator.createMockPane(
        udid: "udid-a", sessionId: sessionA, backend: MockDeviceBackend()
    )
    _ = try await coordinator.createMockPane(
        udid: "udid-b", sessionId: sessionB, backend: MockDeviceBackend()
    )
    #expect(await coordinator.liveOwnerSessionIds == [sessionA, sessionB])
    #expect(await coordinator.paneCount == 2)

    await coordinator.markPanesShutdown(forUDID: "udid-a")
    #expect(await coordinator.liveOwnerSessionIds == [sessionB])
    #expect(await coordinator.paneCount == 2)
}

@Test
func closeRemovesAnExistingPaneRecord() async throws {
    // A GUI `close` tears the record down outright, unlike a shutdown
    // notification, which leaves a `.shutdown` record behind. So a closed
    // pane's owner also drops from the live set, and the record count falls.
    let coordinator = PaneCoordinator()
    let session = UUID()
    let result = try await coordinator.createMockPane(
        udid: "udid-a", sessionId: session, backend: MockDeviceBackend()
    )
    #expect(await coordinator.paneCount == 1)
    #expect(await coordinator.liveOwnerSessionIds == [session])

    _ = await coordinator.close(paneId: result.paneId, as: .guiPeer, mode: .detach)
    #expect(await coordinator.paneCount == 0)
    #expect(await coordinator.liveOwnerSessionIds.isEmpty)
}

// MARK: - Terminal-state teardown

// A pane reaches a terminal state two ways: `markPanesShutdown` on a sim
// shutdown notification, and `markPaneFailed` on an unrecoverable backend
// fault. Both run the same teardown, and most of that teardown is invisible
// to the pane's own state field: the backend is released, the retained
// surface is dropped so the kernel can reclaim the IOSurface, subscribers
// are told, and the owning session's event stream is published to. These
// pin the observable half of that sequence, so a step going missing fails a
// test rather than passing quietly.

@Test("a shutdown releases the backend")
func shutdownReleasesTheBackend() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(
        udid: "teardown-shutdown", sessionId: UUID(), backend: backend
    )

    await coordinator.markPanesShutdown(forUDID: "teardown-shutdown")

    #expect(backend.shutdownCalled)
    // The record survives (the GUI still draws its shutdown overlay), but
    // its backend is gone, so an input verb has nothing to send to.
    await #expect(throws: PaneError.paneNotActive(paneId: pane.paneId)) {
        try await coordinator.tap(paneId: pane.paneId, as: .guiPeer, x: 1, y: 1)
    }
}

@Test("a failure releases the backend")
func failureReleasesTheBackend() async throws {
    let coordinator = PaneCoordinator()
    let backend = MockDeviceBackend()
    let pane = try await coordinator.createMockPane(
        udid: "teardown-failed", sessionId: UUID(), backend: backend
    )

    await coordinator.markPaneFailed(paneId: pane.paneId, reason: "surface pool exhausted")

    #expect(backend.shutdownCalled)
    await #expect(throws: PaneError.paneNotActive(paneId: pane.paneId)) {
        try await coordinator.tap(paneId: pane.paneId, as: .guiPeer, x: 1, y: 1)
    }
}

@Test("a terminal state tells subscribers", arguments: [
    (PaneLifecycle.shutdown, "teardown-sub-shutdown"),
    (PaneLifecycle.failed, "teardown-sub-failed")
])
func terminalStateReachesSubscribers(state: PaneLifecycle, udid: String) async throws {
    let coordinator = PaneCoordinator()
    let pane = try await coordinator.createMockPane(
        udid: udid, sessionId: UUID(), backend: MockDeviceBackend()
    )
    let (_, stream) = try await coordinator.subscribe(paneId: pane.paneId, as: .guiPeer)
    var iterator = stream.makeAsyncIterator()
    // Subscribing replays the pane's current state and orientation; drain
    // both so the next event is the terminal transition.
    _ = await iterator.next()
    _ = await iterator.next()

    if state == .shutdown {
        await coordinator.markPanesShutdown(forUDID: udid)
    } else {
        await coordinator.markPaneFailed(paneId: pane.paneId, reason: "fault")
    }

    let event = try #require(await iterator.next())
    guard case let .stateChanged(eventPaneId, eventState) = event else {
        Issue.record("expected a stateChanged event, got \(event)")
        return
    }
    #expect(eventPaneId == pane.paneId)
    #expect(eventState == state)
}

@Test("a shutdown publishes to the owning session's event stream")
func shutdownPublishesPaneStateChanged() async throws {
    let broker = EventBroker()
    let coordinator = PaneCoordinator(eventBroker: broker)
    let session = UUID()
    let (_, stream) = await broker.subscribe(as: .session(session, incarnation: nil))
    _ = try await coordinator.createMockPane(
        udid: "teardown-evt-shutdown", sessionId: session, backend: MockDeviceBackend()
    )
    var iterator = stream.makeAsyncIterator()
    // Create publishes the pane's initial state; drain it.
    _ = await iterator.next()

    await coordinator.markPanesShutdown(forUDID: "teardown-evt-shutdown")

    let event = try #require(await iterator.next())
    #expect(event.type == DaemonEventType.paneStateChanged)
    #expect(event.state == PaneLifecycle.shutdown.rawValue)
    #expect(event.udid == "teardown-evt-shutdown")
}

@Test("a failure publishes to the owning session's event stream")
func failurePublishesPaneStateChanged() async throws {
    let broker = EventBroker()
    let coordinator = PaneCoordinator(eventBroker: broker)
    let session = UUID()
    let (_, stream) = await broker.subscribe(as: .session(session, incarnation: nil))
    let pane = try await coordinator.createMockPane(
        udid: "teardown-evt-failed", sessionId: session, backend: MockDeviceBackend()
    )
    var iterator = stream.makeAsyncIterator()
    _ = await iterator.next()

    await coordinator.markPaneFailed(paneId: pane.paneId, reason: "surface pool exhausted")

    let event = try #require(await iterator.next())
    #expect(event.type == DaemonEventType.paneStateChanged)
    #expect(event.state == PaneLifecycle.failed.rawValue)
}

@Test("repeated terminal-state updates after shutdown publish nothing further")
func terminalRetireIsIdempotent() async throws {
    let broker = EventBroker()
    let coordinator = PaneCoordinator(eventBroker: broker)
    let session = UUID()
    let (_, stream) = await broker.subscribe(as: .session(session, incarnation: nil))
    let pane = try await coordinator.createMockPane(
        udid: "teardown-idempotent", sessionId: session, backend: MockDeviceBackend()
    )
    var iterator = stream.makeAsyncIterator()
    _ = await iterator.next()

    await coordinator.markPanesShutdown(forUDID: "teardown-idempotent")
    _ = await iterator.next()

    // Repeat both terminal paths against the now-terminal record, then
    // publish a sentinel. If either repeat emitted, the sentinel would not
    // be the next event, so this reads a *negative* deterministically
    // instead of waiting on a stream that should stay silent.
    await coordinator.markPanesShutdown(forUDID: "teardown-idempotent")
    await coordinator.markPaneFailed(paneId: pane.paneId, reason: "already gone")
    await broker.publish(.deviceBooted(udid: "sentinel"), to: .session(session))

    let next = try #require(await iterator.next())
    #expect(next.type == DaemonEventType.deviceBooted)
    #expect(next.udid == "sentinel")
}
