// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreVideo
@testable import Daemon
import DaemonProtocol
import Foundation
import InteractionRelay
import IOSurface
import MirrorPipeline
import Testing

// Hermetic coverage for the physical-device backend. The live behavior (frames
// flowing, touch landing) is the device track; what's testable without hardware
// is the load-bearing surface copy, the button mapping, the no-device error
// paths, the reported capabilities (from the relay's support), and that the
// backend copies a decoded frame into its own surface before publishing.

// MARK: - Fakes

/// A feed that yields a fixed set of frames then finishes.
private final class FakeFeed: DecodedFrameFeed, @unchecked Sendable {
    private let frames: [DecodedFrame]
    private(set) var stopped = false

    /// Runs out of frames rather than failing or disconnecting.
    let termination = FeedTermination.stopped

    init(frames: [DecodedFrame] = []) { self.frames = frames }

    func frames(onFatal: @escaping @Sendable (String) -> Void) -> AsyncStream<DecodedFrame> {
        AsyncStream { continuation in
            for frame in frames { continuation.yield(frame) }
            continuation.finish()
        }
    }

    func stop() { stopped = true }
}

/// A feed whose stream stays open until the test ends it, so a disconnect can
/// be told apart from a teardown. `FakeFeed` finishes immediately, which races
/// any `stopFrames` the test wants to land first.
private final class ControlledFeed: DecodedFrameFeed, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<DecodedFrame>.Continuation?
    private var onFatal: (@Sendable (String) -> Void)?
    private var verdict = FeedTermination.active
    private(set) var stopped = false

    var termination: FeedTermination {
        lock.lock(); defer { lock.unlock() }; return verdict
    }

    func frames(onFatal: @escaping @Sendable (String) -> Void) -> AsyncStream<DecodedFrame> {
        AsyncStream { continuation in
            lock.lock()
            self.continuation = continuation
            self.onFatal = onFatal
            lock.unlock()
        }
    }

    /// End the stream the way `MirrorPipeline.disconnect` does: settle the
    /// verdict, then finish. This is what an unplug actually produces, once
    /// the pipeline has burned its restart budget on a device that had been
    /// mirroring.
    func endStream() {
        lock.lock()
        verdict = .disconnected
        let pending = continuation
        continuation = nil
        onFatal = nil
        lock.unlock()
        pending?.finish()
    }

    /// End the stream the way `MirrorPipeline.fail` does, in that order: the
    /// verdict is settled, then the stream finishes, and only afterwards does
    /// the fatal callback run. A consumer that treats the end of the stream as
    /// a disconnect can lose that race, so the ordering here is the point of
    /// the fake.
    func failStream(_ reason: String) {
        lock.lock()
        verdict = .failed
        let pending = continuation
        let fatal = onFatal
        continuation = nil
        onFatal = nil
        lock.unlock()
        pending?.finish()
        fatal?(reason)
    }

    func stop() { stopped = true }
}

/// A hostile feed that deliberately retains its `onFatal` callback and never
/// clears it, even on `stop` (unlike the real `MirrorPipeline`, which clears it
/// on every terminal path). This isolates the backend's weak capture: with a
/// *strong* capture the retained callback would keep the backend alive
/// (`backend → feed → onFatal → backend`); with the weak capture it does not.
private final class RetainingFeed: DecodedFrameFeed, @unchecked Sendable {
    private var retained: (@Sendable (String) -> Void)?

    let termination = FeedTermination.stopped

    func frames(onFatal: @escaping @Sendable (String) -> Void) -> AsyncStream<DecodedFrame> {
        retained = onFatal
        return AsyncStream { $0.finish() }
    }

    func stop() {} // intentionally keeps `retained` so only a weak capture avoids the cycle
}

/// A relay that records the intents it is asked to perform.
private struct RelayReleaseFailure: Error {}
private struct RelayRotationFailure: Error {}

private actor FakeRelay: InteractionRelaying {
    nonisolated let support: InteractionSupport
    private let failReleases: Bool
    /// Throw on every `.rotate` beyond this many, so a test can let the
    /// establish step succeed (reporting an orientation) and then have a later
    /// step fail, exercising the thrown-step-vs-dead-reckoning distinction.
    private let rotateThrowsAfter: Int?
    private var rotationOutcomes: [InteractionOutcome]
    private var rotateCount = 0
    private var log: [String] = []

    init(
        support: InteractionSupport,
        failReleases: Bool = false,
        rotateThrowsAfter: Int? = nil,
        rotationOutcomes: [InteractionOutcome] = []
    ) {
        self.support = support
        self.failReleases = failReleases
        self.rotateThrowsAfter = rotateThrowsAfter
        self.rotationOutcomes = rotationOutcomes
    }

    /// A release phase (touch lift, key up, button release): the intents the
    /// transfer quiesce sends to neutralize held state. `failReleases` makes
    /// exactly these throw, so a test can drive the `allReleased == false`
    /// abort path without a live device.
    private static func isRelease(_ intent: InteractionIntent) -> Bool {
        switch intent {
        case let .touch(input):
            input.phase == .lift

        case .keyUp:
            true

        case let .button(input):
            input.phase == .release

        case .keyDown, .rotate:
            false
        }
    }

    private static func label(_ intent: InteractionIntent) -> String {
        switch intent {
        case let .touch(input):
            "touch.\(input.phase == .contact ? "contact" : "lift")"

        case .keyDown:
            "keyDown"

        case .keyUp:
            "keyUp"

        case let .button(input):
            "button.\(input.phase == .press ? "press" : "release")"

        case let .rotate(direction):
            "rotate.\(direction.rawValue)"
        }
    }

    func perform(_ intent: InteractionIntent) throws -> InteractionOutcome {
        if failReleases, Self.isRelease(intent) { throw RelayReleaseFailure() }
        if case .rotate = intent {
            rotateCount += 1
            if let limit = rotateThrowsAfter, rotateCount > limit { throw RelayRotationFailure() }
        }
        log.append(Self.label(intent))
        if case .rotate = intent {
            if !rotationOutcomes.isEmpty { return rotationOutcomes.removeFirst() }
            return .orientation("portrait")
        }
        return .acknowledged
    }

    func performed() -> [String] { log }
}

private let touchOnly = InteractionSupport(touch: true, keyboard: true, buttons: false, rotation: false)
private let withButtons = InteractionSupport(touch: true, keyboard: true, buttons: true, rotation: false)
private let full = InteractionSupport(touch: true, keyboard: true, buttons: true, rotation: true)

private func backend(_ support: InteractionSupport, feed: FakeFeed = FakeFeed()) -> RealDeviceBackend {
    RealDeviceBackend(deviceId: "test-device", feed: feed, device: FakeRelay(support: support))
}

private func fill(_ surface: IOSurfaceRef, byte: UInt8) {
    IOSurfaceLock(surface, [], nil)
    memset(
        IOSurfaceGetBaseAddress(surface),
        Int32(byte),
        IOSurfaceGetHeight(surface) * IOSurfaceGetBytesPerRow(surface)
    )
    IOSurfaceUnlock(surface, [], nil)
}

private func firstByte(_ surface: IOSurfaceRef) -> UInt8 {
    IOSurfaceLock(surface, .readOnly, nil)
    defer { IOSurfaceUnlock(surface, .readOnly, nil) }
    return IOSurfaceGetBaseAddress(surface).load(as: UInt8.self)
}

private func identity(_ surface: IOSurfaceRef) -> UInt {
    UInt(bitPattern: Unmanaged.passUnretained(surface).toOpaque())
}

// MARK: - Daemon-owned surface copy

@Test
func surfaceCopyReproducesSourceBytes() throws {
    let source = try #require(SurfaceCopy.makeSurface(width: 8, height: 8))
    let destination = try #require(SurfaceCopy.makeSurface(width: 8, height: 8))
    fill(source, byte: 0xAB)
    fill(destination, byte: 0x00)
    SurfaceCopy.copy(from: source, to: destination)
    #expect(firstByte(destination) == 0xAB)
}

@Test
func surfaceCopyMatchesSourceDimensionsAndContent() throws {
    let source = try #require(SurfaceCopy.makeSurface(width: 12, height: 20))
    fill(source, byte: 0x5A)
    let owned = try #require(SurfaceCopy.makeSurface(width: 12, height: 20))
    SurfaceCopy.copy(from: source, to: owned, contentSize: nil)
    #expect(IOSurfaceGetWidth(owned) == 12)
    #expect(IOSurfaceGetHeight(owned) == 20)
    #expect(firstByte(owned) == 0x5A)
}

// MARK: - Capabilities (from the relay's support)

@Test
func capabilitiesMirrorRelaySupport() {
    let capabilities = backend(touchOnly).capabilities
    #expect(capabilities.touch)
    #expect(capabilities.key)
    #expect(capabilities.text)
    #expect(!capabilities.button)
    #expect(!capabilities.rotate)
    #expect(!capabilities.crown)
    #expect(!capabilities.accessibility)
}

@Test
func buttonCapabilityReflectsSupport() {
    #expect(!backend(touchOnly).capabilities.button)
    #expect(backend(withButtons).capabilities.button)
}

@Test
func rotateCapabilityReflectsSupport() {
    #expect(!backend(touchOnly).capabilities.rotate)
    #expect(!backend(withButtons).capabilities.rotate) // buttons present, rotation absent
    #expect(backend(full).capabilities.rotate)
}

// MARK: - Button mapping (press durations stay in the daemon)

@Test
func physicalButtonMappingsUseDevicetermPressIntervals() {
    #expect(RealDeviceBackend.buttonPress(for: .home) == .init(control: .home, holdNanos: 80_000_000))
    #expect(RealDeviceBackend.buttonPress(for: .lock) == .init(control: .power, holdNanos: 350_000_000))
    #expect(RealDeviceBackend.buttonPress(for: .side) == .init(control: .power, holdNanos: 350_000_000))
    #expect(RealDeviceBackend.buttonPress(for: .siri) == .init(control: .assistant, holdNanos: 750_000_000))
    #expect(RealDeviceBackend.buttonPress(for: .applePay) == nil)
    #expect(RealDeviceBackend.buttonPress(for: .digitalCrown) == nil)
}

// MARK: - Verb gating

@Test
func unwiredVerbsThrowRatherThanSilentlyNoOp() async {
    let device = backend(touchOnly)
    #expect(throws: (any Error).self) { try device.twoFingerDown(f1: .zero, f2: .zero, generation: 1) }
    #expect(throws: (any Error).self) { try device.pressHardwareButton(.home, generation: 1) }
    await #expect(throws: (any Error).self) {
        _ = try await device.rotate(
            target: .absolute(.portrait),
            confirmedOrientation: nil,
            generation: 1
        )
    }
    #expect(throws: Never.self) { try device.keyDown(hidUsage: 4, generation: 1) }
    #expect(throws: Never.self) { try device.keyUp(hidUsage: 4, generation: 1) }
}

@Test
func physicalDeviceDoesNotDriveTheScriptedCoordinateEdgeSwipe() {
    // Gates only the *scripted* coordinate edge swipe: a device can't route a
    // plain coordinate edge swipe to SpringBoard, so the menu/CLI App Switcher
    // takes the device path (`openAppSwitcher`). A live edge drag still works.
    #expect(!backend(touchOnly).supportsSystemEdgeGesture)
}

@Test
func liveEdgeTouchEnqueuesSystemGestureContacts() {
    let device = backend(touchOnly)
    #expect(throws: Never.self) { try device.edgeTouchDown(at: CGPoint(x: 0.5, y: 0.99), edge: 3, generation: 1) }
    #expect(throws: Never.self) { try device.edgeTouchMove(at: CGPoint(x: 0.5, y: 0.5), edge: 3, generation: 1) }
    #expect(throws: Never.self) { try device.edgeTouchUp(at: CGPoint(x: 0.5, y: 0.5), edge: 3, generation: 1) }
}

@Test
func supportedButtonsEnqueueWhileApplePayAndCrownStayUnsupported() {
    let device = backend(withButtons)
    #expect(throws: Never.self) { try device.pressHardwareButton(.home, generation: 1) }
    #expect(throws: Never.self) { try device.pressHardwareButton(.lock, generation: 1) }
    #expect(throws: Never.self) { try device.pressHardwareButton(.side, generation: 1) }
    #expect(throws: Never.self) { try device.pressHardwareButton(.siri, generation: 1) }
    #expect(throws: (any Error).self) { try device.pressHardwareButton(.applePay, generation: 1) }
    #expect(throws: (any Error).self) { try device.pressHardwareButton(.digitalCrown, generation: 1) }
}

@Test
func rotatePerformsWhenSupportedElseThrows() async {
    await #expect(throws: Never.self) {
        _ = try await backend(full).rotate(
            target: .absolute(.landscapeLeft),
            confirmedOrientation: nil,
            generation: 1
        )
    }
    await #expect(throws: (any Error).self) {
        _ = try await backend(touchOnly).rotate(
            target: .absolute(.landscapeLeft),
            confirmedOrientation: nil,
            generation: 1
        )
    }
}

// MARK: - Lifecycle and publication

@Test
func aFrameStreamEndingOnItsOwnReportsADisconnect() async throws {
    // A feed that classified its own ending as retryable, with nobody having
    // asked it to stop. The pane has to hear about it, or it holds a frozen
    // last frame with no signal.
    let feed = ControlledFeed()
    let backend = RealDeviceBackend(
        deviceId: "test-device",
        feed: feed,
        device: FakeRelay(support: touchOnly)
    )
    let disconnected = CompletionFlag()
    try backend.startFrames(
        onFrame: { _ in },
        onFatal: { _ in },
        onDisconnect: { disconnected.set() }
    )
    feed.endStream()
    try await waitUntil { disconnected.isSet }
    #expect(disconnected.isSet)
}

@Test(arguments: [true, false])
func aDeliberateTeardownReportsNoDisconnect(viaShutdown: Bool) async throws {
    // The other half, and the one that matters: both teardown paths end the
    // same loop, so without the run-token fence each would report itself as a
    // disconnect and resurrect a pane the user just closed.
    let feed = ControlledFeed()
    let backend = RealDeviceBackend(
        deviceId: "test-device",
        feed: feed,
        device: FakeRelay(support: touchOnly)
    )
    let disconnected = CompletionFlag()
    try backend.startFrames(
        onFrame: { _ in },
        onFatal: { _ in },
        onDisconnect: { disconnected.set() }
    )
    if viaShutdown {
        backend.shutdownBackend()
    } else {
        backend.stopFrames()
    }
    feed.endStream()
    // Negative assertion, so give the report its chance to arrive before
    // confirming it never did.
    try? await waitUntil({ disconnected.isSet }, within: .milliseconds(200))
    #expect(!disconnected.isSet)
}

@Test
func aFatalFeedFailureReportsNoDisconnect() async throws {
    // A terminal pipeline failure finishes the stream too, and finishes it
    // *before* it calls `onFatal`. Treating the end of the stream as a
    // disconnect therefore races the fatal report, and losing that race takes
    // `.shutdown` instead of `.failed`: the reconnect overlay, then a
    // re-attach straight into the same failure on the next resurrect tick.
    let feed = ControlledFeed()
    let backend = RealDeviceBackend(
        deviceId: "test-device",
        feed: feed,
        device: FakeRelay(support: touchOnly)
    )
    let disconnected = CompletionFlag()
    let failed = CompletionFlag()
    try backend.startFrames(
        onFrame: { _ in },
        onFatal: { _ in failed.set() },
        onDisconnect: { disconnected.set() }
    )

    feed.failStream("decode gave up")

    try await waitUntil { failed.isSet }
    // Negative half: give the disconnect its chance to arrive late before
    // confirming it never came.
    try? await waitUntil({ disconnected.isSet }, within: .milliseconds(200))
    #expect(failed.isSet)
    #expect(!disconnected.isSet)
}

@Test
func aStreamEndingWithoutADisconnectVerdictReportsNothing() async throws {
    // The report is allowlisted on `.disconnected` rather than excluding the
    // endings we know about, so a feed that ends for some other reason, or
    // classifies nothing at all, leaves the pane alone instead of
    // re-mirroring on a guess.
    let backend = RealDeviceBackend(
        deviceId: "test-device",
        feed: FakeFeed(),
        device: FakeRelay(support: touchOnly)
    )
    let disconnected = CompletionFlag()
    try backend.startFrames(
        onFrame: { _ in },
        onFatal: { _ in },
        onDisconnect: { disconnected.set() }
    )
    try? await waitUntil({ disconnected.isSet }, within: .milliseconds(200))
    #expect(!disconnected.isSet)
}

@Test
func backendDeallocatesAfterShutdown() async throws {
    // `RetainingFeed` holds the backend's fenced fatal callback and never clears
    // it, so a strong capture there would form a `backend → feed → onFatal →
    // backend` cycle that outlives the pane. With the weak capture, the backend
    // deallocates once its owner drops it.
    weak var leaked: RealDeviceBackend?
    do {
        let backend = RealDeviceBackend(
            deviceId: "test-device",
            feed: RetainingFeed(),
            device: FakeRelay(support: touchOnly)
        )
        leaked = backend
        try backend.startFrames(onFrame: { _ in }, onFatal: { _ in }, onDisconnect: {})
        backend.shutdownBackend()
    }
    // Bounded wait: ARC reclaims the backend as soon as the last strong ref drops
    // (a strong-capture cycle would keep `leaked` non-nil until the timeout).
    var attempts = 0
    while leaked != nil, attempts < 200 {
        attempts += 1
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(leaked == nil, "backend leaked — retain cycle via the feed's retained onFatal")
}

@Test
func transferFenceDropsStaleBufferedInputAndAdmitsFreshAfterResume() async throws {
    // The physical input fence: after quiesce bumps the generation, an input
    // carrying the *old* generation is dropped by the pump (never reaches the
    // relay); after resume opens a fresh generation, input carrying it is
    // admitted. Uses the ungated button pump so no media-stream frame is
    // needed to open a gate.
    let relay = FakeRelay(support: withButtons)
    let device = RealDeviceBackend(deviceId: "test-device", feed: FakeFeed(), device: relay)
    let stale = device.currentInputGeneration()

    _ = await device.quiesceInputForTransfer()
    // Stale-generation press: dropped.
    try device.pressHardwareButton(.home, generation: stale)
    try await Task.sleep(for: .milliseconds(200))
    #expect(await relay.performed().isEmpty, "a stale-generation press reached the device")

    // Fresh generation after resume: admitted (press → hold → release).
    device.resumeInput()
    try device.pressHardwareButton(.home, generation: device.currentInputGeneration())
    try await Task.sleep(for: .milliseconds(300))
    #expect(await relay.performed() == ["button.press", "button.release"])
}

@Test
func transferQuiesceReleasesAHeldTouchContact() async throws {
    // A held touch contact (a `.down` with no matching `.up`) is released by
    // the transfer quiesce, so the new owner doesn't inherit a finger down.
    let pixelBuffer = try #require(makePixelBuffer(width: 16, height: 16))
    let relay = FakeRelay(support: touchOnly)
    let device = RealDeviceBackend(
        deviceId: "test-device",
        feed: FakeFeed(frames: [DecodedFrame(pixelBuffer: pixelBuffer)]),
        device: relay
    )
    try device.startFrames(onFrame: { _ in }, onFatal: { _ in }, onDisconnect: {})

    // Hold a contact down (the gated pump opens on the first frame).
    try device.tapDown(at: CGPoint(x: 0.5, y: 0.5), generation: device.currentInputGeneration())
    try await waitUntil { await relay.performed().contains("touch.contact") }

    // Quiesce must lift it: a `touch.lift` reaches the relay.
    let clean = await device.quiesceInputForTransfer()
    #expect(clean)
    try await waitUntil { await relay.performed().contains("touch.lift") }
    device.shutdownBackend()
}

@Test
func transferFenceDropsInputBufferedBeforeTheGateOpens() async throws {
    // The sharper physical-fence case: input already *buffered* when quiesce
    // begins (parked behind the closed first-frame gate) must be dropped, not
    // replayed when the gate later opens. The prior test enqueues its stale
    // press only after quiesce returns; this one proves the buffer that exists
    // at quiesce time is fenced too.
    let pixelBuffer = try #require(makePixelBuffer(width: 16, height: 16))
    let relay = FakeRelay(support: touchOnly)
    let device = RealDeviceBackend(
        deviceId: "test-device",
        feed: FakeFeed(frames: [DecodedFrame(pixelBuffer: pixelBuffer)]),
        device: relay
    )
    let stale = device.currentInputGeneration()

    // Park a tap behind the closed gate; frames not started, so the human
    // pump is blocked waiting for the first frame and the tap stays buffered.
    try device.tapDown(at: CGPoint(x: 0.5, y: 0.5), generation: stale)

    // Quiesce bumps the generation while the tap is still buffered.
    _ = await device.quiesceInputForTransfer()

    // Open the gate; the buffered, now-stale tap is drained and dropped.
    try device.startFrames(onFrame: { _ in }, onFatal: { _ in }, onDisconnect: {})
    try await Task.sleep(for: .milliseconds(200))
    #expect(await relay.performed().isEmpty, "a tap buffered before quiesce reached the device")

    // Fresh-generation input after resume is admitted through the open gate.
    device.resumeInput()
    try device.tapDown(at: CGPoint(x: 0.5, y: 0.5), generation: device.currentInputGeneration())
    try await waitUntil { await relay.performed().contains("touch.contact") }
    device.shutdownBackend()
}

@Test
func quiesceReportsNotCleanWhenAHeldReleaseFails() async throws {
    // The `allReleased == false` abort path: a held contact whose lift send
    // *fails* leaves the device possibly-still-holding input, so quiesce
    // returns false (the coordinator then aborts the transfer rather than
    // flipping ownership) and the contact stays held for a later retry.
    let pixelBuffer = try #require(makePixelBuffer(width: 16, height: 16))
    let relay = FakeRelay(support: touchOnly, failReleases: true)
    let device = RealDeviceBackend(
        deviceId: "test-device",
        feed: FakeFeed(frames: [DecodedFrame(pixelBuffer: pixelBuffer)]),
        device: relay
    )
    try device.startFrames(onFrame: { _ in }, onFatal: { _ in }, onDisconnect: {})

    try device.tapDown(at: CGPoint(x: 0.5, y: 0.5), generation: device.currentInputGeneration())
    try await waitUntil { await relay.performed().contains("touch.contact") }

    let clean = await device.quiesceInputForTransfer()
    #expect(!clean, "a failed lift must report the device as not input-clean")
    device.shutdownBackend()
}

@Test
func rotateConfirmsWhenTheDeviceReachesTheTarget() async throws {
    // The fake relay reports portrait, so an absolute request to portrait
    // confirms from that reply.
    let relay = FakeRelay(support: full)
    let device = RealDeviceBackend(deviceId: "test-device", feed: FakeFeed(), device: relay)

    let outcome = try await device.rotate(
        target: .absolute(.portrait),
        confirmedOrientation: nil,
        generation: device.currentInputGeneration()
    )
    #expect(outcome == .confirmed(target: .portrait, observed: .portrait))
    #expect(await relay.performed().contains("rotate.left"))
}

@Test
func rotateReportsUnconfirmedWhenTheDeviceCannotReachTheTarget() async throws {
    // The relay never reports landscapeLeft, so bounded convergence returns
    // the last observation instead of dead-reckoning success.
    let relay = FakeRelay(support: full)
    let device = RealDeviceBackend(deviceId: "test-device", feed: FakeFeed(), device: relay)

    let outcome = try await device.rotate(
        target: .absolute(.landscapeLeft),
        confirmedOrientation: nil,
        generation: device.currentInputGeneration()
    )
    #expect(outcome == .unconfirmed(target: .landscapeLeft, observed: .portrait))
}

@Test
func rotateReportsConfirmationUnsupportedWhenTheRelayOmitsOrientation() async throws {
    let relay = FakeRelay(
        support: full,
        rotationOutcomes: [.orientation(nil)]
    )
    let device = RealDeviceBackend(deviceId: "test-device", feed: FakeFeed(), device: relay)

    let outcome = try await device.rotate(
        target: .relative(.left),
        confirmedOrientation: .landscapeRight,
        generation: device.currentInputGeneration()
    )

    #expect(outcome == .confirmationUnsupported(target: nil))
    #expect(await relay.performed() == ["rotate.left"])
}

@Test
func rotatePropagatesARelayFailureWithoutDeadReckoning() async throws {
    // A thrown relay step is a real failure, not a dead-reckoned success: the
    // establish step succeeds (reports portrait), the next step throws, and
    // even though dead reckoning could predict an orientation, the relay error
    // remains a genuine infrastructure failure.
    let relay = FakeRelay(support: full, rotateThrowsAfter: 1)
    let device = RealDeviceBackend(deviceId: "test-device", feed: FakeFeed(), device: relay)

    // Target != portrait, so a second (throwing) step is required.
    await #expect(throws: RelayRotationFailure.self) {
        try await device.rotate(
            target: .absolute(.landscapeLeft),
            confirmedOrientation: nil,
            generation: device.currentInputGeneration()
        )
    }
}

@Test
func rotateReportsUnavailableWhenFencedByAStaleGeneration() async throws {
    // A transfer bumps the generation first. The stale rotation is dropped by
    // the pump and reports unavailable without reaching the device.
    let relay = FakeRelay(support: full)
    let device = RealDeviceBackend(deviceId: "test-device", feed: FakeFeed(), device: relay)
    let stale = device.currentInputGeneration()

    _ = await device.quiesceInputForTransfer() // bumps the generation
    let outcome = try await device.rotate(
        target: .absolute(.portrait),
        confirmedOrientation: nil,
        generation: stale
    )
    #expect(outcome == .unavailable(target: .portrait))
    #expect(await relay.performed().isEmpty, "a fenced rotation reached the device")
}

@Test
func aRelativeRotationIsSentDirectlyWithoutAStaleAbsoluteBase() async throws {
    let relay = FakeRelay(support: full)
    let device = RealDeviceBackend(deviceId: "test-device", feed: FakeFeed(), device: relay)

    let outcome = try await device.rotate(
        target: .relative(.right),
        confirmedOrientation: .landscapeLeft,
        generation: device.currentInputGeneration()
    )

    #expect(outcome == .confirmed(target: .portrait, observed: .portrait))
    #expect(await relay.performed() == ["rotate.right"])
}

@Test
func inFlightButtonCompletesAfterShutdown() async throws {
    // The `DeviceBackend` contract: an input enqueued before `shutdownBackend`
    // still delivers: the input pumps are not torn down, only frames are.
    let relay = FakeRelay(support: withButtons)
    let device = RealDeviceBackend(deviceId: "test-device", feed: FakeFeed(), device: relay)
    try device.pressHardwareButton(.home, generation: 1) // press → hold 80ms → release
    device.shutdownBackend()
    // Wait past the hold; both phases must reach the relay.
    try await Task.sleep(for: .milliseconds(300))
    let performed = await relay.performed()
    #expect(performed == ["button.press", "button.release"])
}

@Test
func publishedSurfaceIsNeverTheDecoderSurface() async throws {
    // The decoder owns its pixel buffer; the backend must copy into a pool slot
    // before publishing, so the published surface is never the decoder's.
    let pixelBuffer = try #require(makePixelBuffer(width: 16, height: 16))
    let sourceSurface = try #require(CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue())
    let feed = FakeFeed(frames: [DecodedFrame(pixelBuffer: pixelBuffer)])
    let device = RealDeviceBackend(deviceId: "test-device", feed: feed, device: FakeRelay(support: touchOnly))

    let captured = CapturedSurface()
    try device.startFrames(
        onFrame: { published in
            published.surface.withRef { surface in
                let id = identity(surface)
                Task { await captured.set(id) }
            }
        },
        onFatal: { _ in },
        onDisconnect: {}
    )
    try await waitUntil { await captured.value != nil }
    let publishedIdentity = try #require(await captured.value)
    #expect(publishedIdentity != identity(sourceSurface))
    device.shutdownBackend()
}

// MARK: - Coordinator error mapping

@Test
func resolveBackendThrowsNotConnectedForUnknownDevice() async {
    let coordinator = PhysicalDeviceCoordinator(listDevices: { [] })
    await #expect(throws: PhysicalDeviceError.notConnected(deviceId: "not-a-real-tunnel")) {
        _ = try await coordinator.resolveBackend(deviceId: "not-a-real-tunnel")
    }
}

@Test
func resolveRouteTimeoutMapsToTunnelBringUpFailed() async {
    // A connected-in-roster device whose tunnel never comes up maps the
    // reachability timeout to `tunnelBringUpFailed`.
    let device = DeviceCtlDevice(
        udid: "D",
        name: nil,
        model: nil,
        osVersion: nil,
        transportType: nil,
        tunnelState: "disconnected",
        tunnelIPAddress: nil
    )
    let coordinator = PhysicalDeviceCoordinator(listDevices: { [device] })
    await #expect(throws: PhysicalDeviceError.tunnelBringUpFailed(deviceId: "D")) {
        _ = try await coordinator.resolveRoute(deviceId: "D", attempts: 2, interval: .milliseconds(1))
    }
}

@Test
func attachWithoutAuthenticatedSessionIsRejected() async throws {
    let handler = PhysicalDeviceMethods.attach(
        physicalDeviceCoordinator: PhysicalDeviceCoordinator(listDevices: { [] }),
        paneCoordinator: PaneCoordinator(),
        sessionManager: SessionManager()
    )
    let body = try JSONEncoder().encode(PhysicalDeviceMethods.AttachParams(deviceId: "x"))
    await #expect(throws: (any Error).self) {
        _ = try await handler(body)
    }
}

@Test
func attachWithAuthButNoDeviceReturnsCleanError() async throws {
    let handler = PhysicalDeviceMethods.attach(
        physicalDeviceCoordinator: PhysicalDeviceCoordinator(listDevices: { [] }),
        paneCoordinator: PaneCoordinator(),
        sessionManager: SessionManager()
    )
    let body = try JSONEncoder().encode(PhysicalDeviceMethods.AttachParams(deviceId: "not-a-real-tunnel"))
    await SessionDispatchContext.$originatingSessionId.withValue(UUID().uuidString) {
        await #expect(throws: (any Error).self) {
            _ = try await handler(body)
        }
    }
}

@Test
func mapPhysicalDeviceErrorNotConnectedIsInvalidParams() {
    let mapped = PhysicalDeviceMethods.mapPhysicalDeviceError(.notConnected(deviceId: "d"))
    #expect(mapped.code == RPCMethodError.invalidParamsCode)
}

// MARK: - Test helpers

/// An actor holding the published surface's identity. The frame callback writes
/// it (via a `Task`) and the test reads it, on different tasks, so actor
/// isolation synchronizes the access. Stores the surface pointer's bit pattern (a
/// `Sendable` `UInt`) rather than the raw pointer.
private actor CapturedSurface {
    private(set) var value: UInt?

    func set(_ value: UInt) { self.value = value }
}

private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()]
    CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer
    )
    return buffer
}

private func waitUntil(_ predicate: @Sendable () async -> Bool, within: Duration = .seconds(2)) async throws {
    let deadline = ContinuousClock().now.advanced(by: within)
    while ContinuousClock().now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

// MARK: - Location simulation

/// Records what the backend asked of the location surface, so dispatch
/// can be asserted without a connected device or a `devicectl` spawn.
private actor FakeDeviceLocation: DeviceLocationSimulating {
    private(set) var calls: [String] = []
    var scenarios: [String] = ["City Run", "Freeway Drive"]
    /// When set, every entry point throws it, proving the backend
    /// translates `devicectl` vocabulary into `DeviceBackendError`.
    var failure: (any Error)?
    private let gate: LocationGate?

    init(gate: LocationGate? = nil) { self.gate = gate }

    func fail(with error: any Error) { failure = error }

    func setCoordinate(deviceId: String, latitude: Double, longitude: Double) async throws {
        await gate?.enter()
        calls.append("coordinate(\(deviceId),\(latitude),\(longitude))")
        if let failure { throw failure }
    }

    func setScenario(deviceId: String, name: String) throws {
        calls.append("scenario(\(deviceId),\(name))")
        if let failure { throw failure }
    }

    func startRoute(deviceId: String, spec: RouteSpec) throws {
        calls.append("route(\(deviceId),\(spec.waypoints.count))")
        if let failure { throw failure }
    }

    func clear(deviceId: String) throws {
        calls.append("clear(\(deviceId))")
        if let failure { throw failure }
    }

    func availableScenarios(deviceId: String) throws -> [String] {
        calls.append("list(\(deviceId))")
        if let failure { throw failure }
        return scenarios
    }
}

// MARK: - devicectl error translation

// `PaneCoordinator.setLocation` has a general catch, so an untranslated
// `DeviceCtlLocationError` escaping the backend would be reported as a
// bridge fault rather than leaking as a bare `serverError`. Either way
// the documented parity is lost, where a bad scenario name answers
// `invalidParams` on both backends. Classifying here preserves it, while
// the backend can still read the tool's own vocabulary.

@Test("a rejected scenario name becomes unknownLocationScenario")
func rejectedScenarioTranslatesToBackendVocabulary() async throws {
    let location = FakeDeviceLocation()
    await location.fail(with: DeviceCtlLocationError.unknownScenario(name: "Nope"))
    let subject = locationBackend(location)
    do {
        try await subject.setSimulatedLocationScenario("Nope", generation: subject.currentInputGeneration())
        Issue.record("expected the rejected scenario to throw")
    } catch let DeviceBackendError.unknownLocationScenario(name) {
        #expect(name == "Nope")
    }
}

/// A command that ran and failed maps to `locationCommandFailed`, not
/// `locationUnavailable`, whose wire mapping hardcodes the
/// `location.acquire` label and would misreport a failed
/// `pane.location.set` as an acquisition failure.
@Test("a failed devicectl command becomes locationCommandFailed")
func otherDeviceCtlFailureTranslates() async throws {
    let location = FakeDeviceLocation()
    await location.fail(
        with: DeviceCtlLocationError.commandFailed(status: 1, message: "device not found")
    )
    let subject = locationBackend(location)
    do {
        try await subject.clearSimulatedLocation(generation: subject.currentInputGeneration())
        Issue.record("expected the failed command to throw")
    } catch let DeviceBackendError.locationCommandFailed(message) {
        #expect(message == "device not found")
    }
}

/// The read path bypasses the pump, so it needs its own translation.
///
/// Unreadable output maps to its **own** case rather than the generic
/// `locationUnavailable`, because the two mean opposite things: an
/// unreachable device legitimately has no trips, while unintelligible
/// output means every device will look that way. The distinct error is
/// what keeps schema drift observable instead of being treated as an
/// idle device.
@Test("unreadable enumeration output maps to its own case", arguments: [
    DeviceCtlLocationError.malformedOutput,
    DeviceCtlLocationError.missingOutput
])
func unreadableEnumerationTranslates(failure: DeviceCtlLocationError) async {
    let location = FakeDeviceLocation()
    await location.fail(with: failure)
    let subject = locationBackend(location)
    do {
        _ = try await subject.availableLocationScenarios()
        Issue.record("expected the enumeration to throw")
    } catch DeviceBackendError.locationOutputMalformed {
    } catch {
        Issue.record("expected locationOutputMalformed, got \(error)")
    }
}

/// A device that simply isn't reachable stays routine, so it can't
/// trigger the schema-drift alarm.
@Test("an unreachable device is not reported as malformed output")
func unreachableDeviceIsNotReportedAsMalformed() async {
    let location = FakeDeviceLocation()
    await location.fail(
        with: DeviceCtlLocationError.commandFailed(status: 1, message: "device not found")
    )
    let subject = locationBackend(location)
    do {
        _ = try await subject.availableLocationScenarios()
        Issue.record("expected the enumeration to throw")
    } catch DeviceBackendError.locationCommandFailed {
    } catch {
        Issue.record("expected locationCommandFailed, got \(error)")
    }
}

private func locationBackend(
    _ location: FakeDeviceLocation,
    deviceId: String = "DEV-9"
) -> RealDeviceBackend {
    RealDeviceBackend(
        deviceId: deviceId,
        feed: FakeFeed(),
        device: FakeRelay(support: full),
        location: location
    )
}

@Test("a device pane reports location support regardless of open channels")
func devicePaneReportsLocationCapability() {
    // Location rides `devicectl`, not the relay's channels, so even the
    // most restricted support set keeps it.
    #expect(backend(touchOnly).capabilities.location)
    #expect(backend(full).capabilities.location)
}

@Test("each location verb forwards to the location surface with the deviceId")
func locationVerbsForwardWithDeviceId() async throws {
    let fake = FakeDeviceLocation()
    let subject = locationBackend(fake)

    let generation = subject.currentInputGeneration()
    try await subject.setSimulatedLocation(
        latitude: 37.3349,
        longitude: -122.009,
        generation: generation
    )
    try await subject.setSimulatedLocationScenario("City Run", generation: generation)
    try await subject.startSimulatedLocationRoute(twoPointRoute, generation: generation)
    try await subject.clearSimulatedLocation(generation: generation)
    _ = try await subject.availableLocationScenarios()

    #expect(await fake.calls == [
        "coordinate(DEV-9,37.3349,-122.009)",
        "scenario(DEV-9,City Run)",
        "route(DEV-9,2)",
        "clear(DEV-9)",
        "list(DEV-9)"
    ])
}

private let twoPointRoute = RouteSpec(
    mode: .interval(seconds: 1),
    speed: 20,
    waypoints: [
        RouteWaypoint(latitude: 0, longitude: 0),
        RouteWaypoint(latitude: 1, longitude: 1)
    ]
)

/// A route rides the same pump as the other mutations, so it inherits
/// the ownership-transfer fence rather than needing one of its own. It
/// suspends on `devicectl` for as long as any of them, and it is the
/// longest-lived effect of the four, so a route landing on the new
/// owner's device would be the most visible version of that bug.
@Test("a stale-generation route is dropped, not sent")
func staleRouteIsFenced() async throws {
    let fake = FakeDeviceLocation()
    let subject = locationBackend(fake)
    let stale = subject.currentInputGeneration()
    _ = await subject.quiesceInputForTransfer()

    await #expect(throws: (any Error).self) {
        try await subject.startSimulatedLocationRoute(twoPointRoute, generation: stale)
    }
    #expect(await fake.calls.isEmpty, "a fenced route reached the device")
}

/// Host-side, before `devicectl` is spawned, but still a command
/// failure: the caller asked for a route and got none. Labelling it
/// `locationUnavailable` would blame acquisition, a step this got past.
@Test("an unwritable route file becomes locationCommandFailed")
func routeFileFailureTranslates() async throws {
    let fake = FakeDeviceLocation()
    await fake.fail(with: DeviceCtlLocationError.routeFileUnwritable(message: "disk full"))
    let subject = locationBackend(fake)
    do {
        try await subject.startSimulatedLocationRoute(
            twoPointRoute,
            generation: subject.currentInputGeneration()
        )
        Issue.record("expected the route to throw")
    } catch let DeviceBackendError.locationCommandFailed(message) {
        #expect(message.contains("disk full"))
        #expect(message.contains("route file"))
    }
}

/// Unlike the simulator backend, the device path does not pre-check the
/// name: `devicectl` is a separate process that reports its own failure,
/// and prechecking would add a second subprocess invocation per set.
@Test("an unknown scenario is forwarded for devicectl to reject")
func unknownScenarioIsForwarded() async throws {
    let fake = FakeDeviceLocation()
    let subject = locationBackend(fake)
    try await subject.setSimulatedLocationScenario(
        "Nope",
        generation: subject.currentInputGeneration()
    )
    #expect(await fake.calls == ["scenario(DEV-9,Nope)"])
}

@Test("availableLocationScenarios returns the surface's list")
func availableScenariosPassesThrough() async throws {
    let fake = FakeDeviceLocation()
    let names = try await locationBackend(fake).availableLocationScenarios()
    #expect(names == ["City Run", "Freeway Drive"])
}

/// A location command admitted before an ownership transfer must not
/// land on the new owner's device. The device path suspends on a
/// `devicectl` subprocess, so without the fence a prior owner's command
/// could complete after the flip.
@Test("a stale-generation location command is dropped, not sent")
func staleLocationCommandIsFenced() async throws {
    let fake = FakeDeviceLocation()
    let subject = locationBackend(fake)
    let stale = subject.currentInputGeneration()
    // Transfer: invalidate everything admitted under `stale`.
    _ = await subject.quiesceInputForTransfer()

    await #expect(throws: (any Error).self) {
        try await subject.setSimulatedLocation(
            latitude: 1,
            longitude: 2,
            generation: stale
        )
    }
    #expect(await fake.calls.isEmpty, "a fenced command reached the device")
}

/// The fence must wait out an in-flight command rather than returning
/// while `devicectl` is still running: a transfer that completes mid-set
/// would let the mutation land after ownership flipped.
@Test("quiesce waits for an in-flight location command")
func quiesceWaitsForInFlightLocation() async throws {
    let gate = LocationGate()
    let fake = FakeDeviceLocation(gate: gate)
    let subject = locationBackend(fake)
    let generation = subject.currentInputGeneration()

    let inFlight = Task {
        try await subject.setSimulatedLocation(
            latitude: 1,
            longitude: 2,
            generation: generation
        )
    }
    await gate.waitUntilEntered()

    // Explicit completion signal, because `!quiesce.isCancelled` is true
    // for a running *and* a finished task, so it can't distinguish them.
    let finished = QuiesceSignal()
    let beforeQuiesce = subject.currentInputGeneration()
    let quiesce = Task {
        let clean = await subject.quiesceInputForTransfer()
        await finished.complete()
        return clean
    }
    // Establish that quiesce actually *started* before asserting it hasn't
    // finished: otherwise a task still waiting to be scheduled would leave
    // the signal false and the assertion would pass even with no barrier.
    // Quiesce bumps the generation synchronously as its first step, so a
    // changed generation proves entry.
    var entered = false
    for _ in 0..<200 where !entered {
        if subject.currentInputGeneration() != beforeQuiesce {
            entered = true
            break
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(entered, "quiesce never started")
    // Now the barrier is the only thing that can still be holding it.
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(
        await !finished.isComplete,
        "quiesce returned while a location command was still in flight"
    )

    await gate.release()
    try await inFlight.value
    _ = await quiesce.value
    #expect(await finished.isComplete)
    #expect(await fake.calls.count == 1)
}

/// Blocks the fake mid-call so a test can observe the pump while a
/// command is genuinely in flight.
private actor LocationGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters = []
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }
}

/// Records whether `quiesceInputForTransfer` has actually returned, so
/// the fence test asserts completion rather than task liveness.
private actor QuiesceSignal {
    private(set) var isComplete = false
    func complete() { isComplete = true }
}

/// Records that a task ran to completion, which `Task` itself doesn't expose.
private final class CompletionFlag: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.deviceterm.tests.completion-flag")
    private var completed = false

    var isSet: Bool {
        queue.sync { completed }
    }

    func set() {
        queue.sync { completed = true }
    }
}

/// A relay whose App Switcher macro blocks until released, so a test can see
/// whether the caller waits for it and whether cancellation reaches it.
private actor ParkingRelay: InteractionRelaying {
    nonisolated let support: InteractionSupport
    private var release: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private(set) var startedCount = 0
    private(set) var sawCancellation = false

    init(support: InteractionSupport) {
        self.support = support
    }

    /// Returns whether the macro actually reached the relay, so a test fails
    /// loudly rather than passing on a spin that timed out.
    func waitUntilStarted() async -> Bool {
        for _ in 0..<10_000 where !started {
            await Task.yield()
        }
        return started
    }

    func releaseMacro() {
        release?.resume()
        release = nil
    }

    /// Non-throwing: this relay parks rather than failing, and a non-throwing
    /// function satisfies the protocol's throwing requirement.
    @discardableResult
    func perform(_ intent: InteractionIntent) async -> InteractionOutcome {
        guard case let .touch(input) = intent, case .appSwitcher = input.kind else {
            return .acknowledged
        }
        started = true
        startedCount += 1
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            release = continuation
        }
        sawCancellation = input.cancellation?.isCancelled == true
        return .acknowledged
    }
}

@Test
func openAppSwitcherWaitsForTheRelayMacroToFinish() async throws {
    let pixelBuffer = try #require(makePixelBuffer(width: 16, height: 16))
    let relay = ParkingRelay(support: touchOnly)
    let backend = RealDeviceBackend(
        deviceId: "test-device",
        feed: FakeFeed(frames: [DecodedFrame(pixelBuffer: pixelBuffer)]),
        device: relay
    )
    // The gated human-input pump opens on the first frame.
    try backend.startFrames(onFrame: { _ in }, onFatal: { _ in }, onDisconnect: {})
    let completed = CompletionFlag()
    let call = Task {
        try await backend.openAppSwitcher(edge: 3, generation: backend.currentInputGeneration())
        completed.set()
    }
    #expect(await relay.waitUntilStarted())
    // Suspended, not finished: returning while the relay still drives the
    // device would release the pane's lane mid-macro.
    #expect(!completed.isSet)
    await relay.releaseMacro()
    try await call.value
    #expect(completed.isSet)
}

@Test
func aTransferCancelsAnInFlightAppSwitcherWithoutKillingThePump() async throws {
    let pixelBuffer = try #require(makePixelBuffer(width: 16, height: 16))
    let relay = ParkingRelay(support: touchOnly)
    let backend = RealDeviceBackend(
        deviceId: "test-device",
        feed: FakeFeed(frames: [DecodedFrame(pixelBuffer: pixelBuffer)]),
        device: relay
    )
    try backend.startFrames(onFrame: { _ in }, onFatal: { _ in }, onDisconnect: {})
    let call = Task { try await backend.openAppSwitcher(edge: 3, generation: backend.currentInputGeneration()) }
    #expect(await relay.waitUntilStarted())
    backend.cancelAppSwitcherRequests()
    await relay.releaseMacro()
    try await call.value
    // The macro saw the signal, and the pump is still alive for the next verb:
    // cancelling the pump itself would disable input on this pane for good.
    #expect(await relay.sawCancellation)
    backend.resumeInput()
    try backend.tapDown(at: .zero, generation: backend.currentInputGeneration())
}

@Test
func openAppSwitcherGivesUpWhenTheDeviceNeverStreams() async throws {
    let relay = ParkingRelay(support: touchOnly)
    // No frames, so the gated human-input pump never opens and never consumes
    // the macro. An unbounded park would hold the pane's lane forever, and with
    // it a deferred close's cleanup.
    let backend = RealDeviceBackend(deviceId: "test-device", feed: FakeFeed(), device: relay)
    let call = Task { try await backend.openAppSwitcher(edge: 3, generation: backend.currentInputGeneration()) }
    try await call.value
    // It returned, and the macro is cancelled, so it no-ops if the gate opens
    // later and the pump finally drains it.
    #expect(await relay.startedCount == 0)
}
