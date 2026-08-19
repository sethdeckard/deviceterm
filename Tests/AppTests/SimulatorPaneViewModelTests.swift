// SPDX-License-Identifier: GPL-3.0-or-later
//
// The sim pane view model driven by a fake daemon. Lifecycle
// events move state through the reducer, surface.changed applies
// the paired IOSurfaceRef (which arrives alongside the JSON evt),
// input intents forward to pane.input.* RPCs, and close() forwards
// + clears the surface.

@testable import App
import CoreGraphics
import DaemonProtocol
import IOSurface
import Testing

@MainActor
struct SimulatorPaneViewModelTests {
    /// Let the subscription Task / input Tasks run.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 30_000_000)  // 30ms
    }

    /// Poll `condition` until it holds or `maxIterations` 2ms ticks elapse.
    /// Returns whether it held. Replaces fixed wall-clock slack: a positive
    /// assertion waits for the transition (no early sample); a negative
    /// assertion uses a small `maxIterations` so a would-be event (near-
    /// instant under a tiny injected backoff) is given its chance and then
    /// confirmed absent.
    private func poll(
        maxIterations: Int = 1_000,
        _ condition: () -> Bool
    ) async -> Bool {
        for _ in 0..<maxIterations {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)  // 2ms
        }
        return condition()
    }

    /// Wrap a raw surface as an unleased lease (the simulator-frame shape:
    /// no use-count, no release) for driving the VM's surface path.
    private func unleased(_ surface: IOSurfaceRef) -> SurfaceLease {
        SurfaceLease(
            surface: surface,
            paneId: "p1",
            subscriptionToken: UUID(),
            leaseEpoch: 0,
            generation: 0,
            onRelease: nil
        )
    }

    private func makeViewModel(
        _ fake: FakeDaemonClient,
        paneId: String = "p1",
        capabilities: PaneCapabilities? = nil,
        reconnectBackoffNs: UInt64 = 500_000_000
    ) -> SimulatorPaneViewModel {
        SimulatorPaneViewModel(
            paneId: paneId,
            daemonClient: fake,
            udid: "U",
            displayName: "iPhone",
            family: "phone",
            capabilities: capabilities,
            reconnectBackoffNs: reconnectBackoffNs
        )
    }

    @Test
    func lifecycleEventsDriveState() async {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        viewModel.start()
        await settle()
        #expect(fake.subscribePaneCalls == ["p1"])
        #expect(viewModel.state == .booting)

        fake.lastPaneEventContinuation?.yield(
            .stateChanged(StateChangedEvent(paneId: "p1", state: .rendering))
        )
        await settle()
        #expect(viewModel.state == .rendering)

        fake.lastPaneEventContinuation?.yield(
            .stateChanged(StateChangedEvent(paneId: "p1", state: .shutdown))
        )
        await settle()
        #expect(viewModel.state == .shutdown)
    }

    @Test
    func surfaceChangedAppliesRef() async {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        viewModel.start()
        await settle()

        // No bound ref: side-band payload was missing or timed
        // out. The VM records the sequence but doesn't replace
        // currentSurface (the view keeps its last good frame) and
        // doesn't transition out of booting.
        fake.lastPaneEventContinuation?.yield(
            .surfaceChanged(
                SurfaceChangedEvent(paneId: "p1", sequence: 1),
                nil
            )
        )
        await settle()
        #expect(viewModel.currentSequence == 1)
        #expect(viewModel.currentSurface == nil)
        #expect(viewModel.state == .booting)
    }

    @Test
    func surfaceChangedNilRefPreservesLastGoodFrame() async throws {
        // Two cycles: a real surface arrives, then a follow-up
        // nil-ref event (timeout / reorder). The VM must keep
        // the prior surface and not blank the pane.
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        viewModel.start()
        await settle()

        let props: [String: Any] = [
            kIOSurfaceWidth as String: 4,
            kIOSurfaceHeight as String: 4,
            kIOSurfaceBytesPerElement as String: 4,
            kIOSurfacePixelFormat as String: 0x42_47_52_41
        ]
        let surface = try #require(IOSurfaceCreate(props as CFDictionary))
        fake.lastPaneEventContinuation?.yield(
            .surfaceChanged(
                SurfaceChangedEvent(paneId: "p1", sequence: 1),
                unleased(surface)
            )
        )
        await settle()
        #expect(viewModel.currentSurface != nil)
        #expect(viewModel.state == .rendering)

        fake.lastPaneEventContinuation?.yield(
            .surfaceChanged(
                SurfaceChangedEvent(paneId: "p1", sequence: 2),
                nil
            )
        )
        await settle()
        // Last good frame still held.
        #expect(viewModel.currentSurface != nil)
        #expect(viewModel.currentSequence == 2)
        #expect(viewModel.state == .rendering)
    }

    @Test
    func newSequenceReplacesRenderedRefEvenWithDuplicateSurfaceID() async throws {
        // A repeated surface ID with a NEW sequence still carries a fresh frame:
        // physical devices round-robin a small IOSurface ring whose IDs recur every
        // few frames, and simulators update one persistent surface in place. So a
        // duplicate ID MUST replace the rendered ref. Skipping on a matching ID left
        // the device mirror frozen on stale content while fresh frames arrived.
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        viewModel.start()
        await settle()

        let props: [String: Any] = [
            kIOSurfaceWidth as String: 4,
            kIOSurfaceHeight as String: 4,
            kIOSurfaceBytesPerElement as String: 4,
            kIOSurfacePixelFormat as String: 0x42_47_52_41
        ]
        let surface = try #require(IOSurfaceCreate(props as CFDictionary))
        fake.lastPaneEventContinuation?.yield(
            .surfaceChanged(
                SurfaceChangedEvent(paneId: "p1", sequence: 1),
                unleased(surface)
            )
        )
        await settle()

        let surfaceXPC = IOSurfaceCreateXPCObject(surface)
        let duplicate = try #require(IOSurfaceLookupFromXPCObject(surfaceXPC))
        #expect(IOSurfaceGetID(duplicate) == IOSurfaceGetID(surface))
        let duplicatePointer = Unmanaged.passUnretained(duplicate).toOpaque()
        fake.lastPaneEventContinuation?.yield(
            .surfaceChanged(
                SurfaceChangedEvent(paneId: "p1", sequence: 2),
                unleased(duplicate)
            )
        )
        await settle()

        #expect(viewModel.currentSequence == 2)
        // The duplicate carries the SAME IOSurface id as the original, yet the
        // rendered ref must still be replaced: a repeated id carries fresh pixels.
        #expect(IOSurfaceGetID(duplicate) == IOSurfaceGetID(surface))
        let currentRendered = try #require(viewModel.currentSurface)
        #expect(Unmanaged.passUnretained(currentRendered.surface).toOpaque() == duplicatePointer)
        #expect(viewModel.state == .rendering)
    }

    @Test
    func surfaceBurstPublishesNewestFrame() async throws {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        viewModel.start()
        await settle()

        let props: [String: Any] = [
            kIOSurfaceWidth as String: 4,
            kIOSurfaceHeight as String: 4,
            kIOSurfaceBytesPerElement as String: 4,
            kIOSurfacePixelFormat as String: 0x42_47_52_41
        ]
        let first = try #require(IOSurfaceCreate(props as CFDictionary))
        let second = try #require(IOSurfaceCreate(props as CFDictionary))
        fake.lastPaneEventContinuation?.yield(
            .surfaceChanged(
                SurfaceChangedEvent(paneId: "p1", sequence: 1),
                unleased(first)
            )
        )
        fake.lastPaneEventContinuation?.yield(
            .surfaceChanged(
                SurfaceChangedEvent(paneId: "p1", sequence: 2),
                unleased(second)
            )
        )
        await settle()

        #expect(viewModel.currentSequence == 2)
        // The newest frame wins: the rendered ref is the second surface, not the first.
        let rendered = try #require(viewModel.currentSurface)
        #expect(Unmanaged.passUnretained(rendered.surface).toOpaque() == Unmanaged.passUnretained(second).toOpaque())
        #expect(viewModel.state == .rendering)
    }

    @Test
    func inputIntentsForwardToDaemon() async {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        viewModel.tap(at: CGPoint(x: 0.5, y: 0.5))
        viewModel.touch(at: CGPoint(x: 0.4, y: 0.5), phase: .down)
        viewModel.keyDown(keyCode: 4)
        await settle()
        let methods = Set(fake.paneInputCalls.map(\.method))
        #expect(methods == [.paneInputTap, .paneInputTouch, .paneInputKey])
        #expect(fake.paneInputCalls.allSatisfy { $0.paneId == "p1" })
    }

    @Test
    func keyboardEventsReachTheDaemonInAppKitOrder() async {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        viewModel.keyDown(keyCode: 0)
        viewModel.keyUp(keyCode: 0)
        viewModel.keyDown(keyCode: 11)
        viewModel.keyUp(keyCode: 11)
        await settle()
        #expect(fake.keyCalls == [
            .init(paneId: "p1", keyCode: 0, down: true),
            .init(paneId: "p1", keyCode: 0, down: false),
            .init(paneId: "p1", keyCode: 11, down: true),
            .init(paneId: "p1", keyCode: 11, down: false)
        ])
    }

    @Test
    func liveTouchPhasesReachTheDaemonInTheOrderAppKitProducedThem() async {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        // Phases are serialized because neither RPC suspension nor XPC
        // dispatch preserves the order AppKit produced them in.
        viewModel.touch(at: CGPoint(x: 0.5, y: 0.5), phase: .down, edge: nil)
        for step in 1...8 {
            viewModel.touch(at: CGPoint(x: 0.5, y: 0.5 - CGFloat(step) * 0.01), phase: .move, edge: nil)
        }
        viewModel.touch(at: CGPoint(x: 0.5, y: 0.4), phase: .lift, edge: nil)
        await settle()

        let phases = fake.touchCalls.map(\.phase)
        #expect(phases.first == .down)
        #expect(phases.last == .lift)
        #expect(phases.filter { $0 == .down }.count == 1)
        #expect(phases.filter { $0 == .lift }.count == 1)
        // No move escapes ahead of the down or behind the lift.
        let firstMove = phases.firstIndex(of: .move)
        let lastMove = phases.lastIndex(of: .move)
        #expect(firstMove.map { $0 > 0 } ?? true)
        #expect(lastMove.map { $0 < phases.count - 1 } ?? true)
    }

    @Test
    func aNewGesturesMoveIsNotConsumedByThePreviousOne() async {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        // Two drags back to back. Gesture tags are what keep the second drag's
        // move from being sent as part of the first, or cleared by the first's
        // teardown.
        viewModel.touch(at: CGPoint(x: 0.1, y: 0.1), phase: .down, edge: nil)
        viewModel.touch(at: CGPoint(x: 0.1, y: 0.2), phase: .move, edge: nil)
        viewModel.touch(at: CGPoint(x: 0.1, y: 0.3), phase: .lift, edge: nil)
        viewModel.touch(at: CGPoint(x: 0.9, y: 0.1), phase: .down, edge: nil)
        viewModel.touch(at: CGPoint(x: 0.9, y: 0.2), phase: .move, edge: nil)
        viewModel.touch(at: CGPoint(x: 0.9, y: 0.3), phase: .lift, edge: nil)
        await settle()

        let phases = fake.touchCalls.map(\.phase)
        #expect(phases.filter { $0 == .down }.count == 2)
        #expect(phases.filter { $0 == .lift }.count == 2)
        // Each gesture's moves stay on its own side of the pane.
        let firstLift = phases.firstIndex(of: .lift) ?? 0
        let early = fake.touchCalls.prefix(firstLift + 1)
        let late = fake.touchCalls.suffix(from: firstLift + 1)
        #expect(early.allSatisfy { $0.x < 0.5 })
        #expect(late.allSatisfy { $0.x > 0.5 })
    }

    @Test
    func anInFlightMoveDrainsBeforeTheLift() async {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        viewModel.touch(at: CGPoint(x: 0.5, y: 0.9), phase: .down, edge: nil)
        viewModel.touch(at: CGPoint(x: 0.5, y: 0.3), phase: .move, edge: nil)
        viewModel.touch(at: CGPoint(x: 0.5, y: 0.2), phase: .lift, edge: nil)
        await settle()

        // The lift is last, and the move that preceded it was not dropped on
        // the way: a lift landing on a stale position ends the drag somewhere
        // the finger never was.
        let phases = fake.touchCalls.map(\.phase)
        #expect(phases.contains(.move))
        #expect(phases.last == .lift)
        #expect(fake.touchCalls.last?.y == 0.2)
    }

    @Test
    func aFailedSendDoesNotWedgeTheLivePump() async {
        let fake = FakeDaemonClient()
        fake.failTouch = true
        let viewModel = makeViewModel(fake)
        viewModel.touch(at: CGPoint(x: 0.5, y: 0.5), phase: .down, edge: nil)
        await settle()
        fake.failTouch = false
        viewModel.touch(at: CGPoint(x: 0.5, y: 0.4), phase: .lift, edge: nil)
        await settle()

        // The terminal lift still has to land, so a failed send is swallowed
        // rather than ending the pump.
        #expect(fake.touchCalls.map(\.phase).contains(.lift))
    }

    @Test
    func multitouchStreamsDownMoveLiftWithCoalescedMoves() async {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        // A burst of moves between an immediate down and lift. The
        // latest-wins coalescing means at most one move is in flight at a
        // time, so the recorded moves collapse below the eight enqueued.
        viewModel.multitouch(
            phase: .down,
            finger1: .init(x: 0.4, y: 0.5),
            finger2: .init(x: 0.6, y: 0.5)
        )
        for step in 1...8 {
            let delta = CGFloat(step) * 0.01
            viewModel.multitouch(
                phase: .move,
                finger1: .init(x: 0.4 + delta, y: 0.5),
                finger2: .init(x: 0.6 - delta, y: 0.5)
            )
        }
        viewModel.multitouch(
            phase: .lift,
            finger1: .init(x: 0.48, y: 0.5),
            finger2: .init(x: 0.52, y: 0.5)
        )
        await settle()

        let phases = fake.multitouchCalls.map(\.phase)
        #expect(phases.first == .down)
        #expect(phases.last == .lift)
        #expect(phases.filter { $0 == .down }.count == 1)
        #expect(phases.filter { $0 == .lift }.count == 1)
        let moves = phases.filter { $0 == .move }.count
        #expect(moves >= 1 && moves <= 8)
        // The down lands both fingers at the press point; the lift always
        // carries the final position (so the gesture's end point reaches
        // the daemon even when its buffered move was coalesced away).
        #expect(fake.multitouchCalls.first?.finger1 == CGPoint(x: 0.4, y: 0.5))
        #expect(fake.multitouchCalls.last?.finger1 == CGPoint(x: 0.48, y: 0.5))
        #expect(fake.multitouchCalls.allSatisfy { $0.paneId == "p1" })
    }

    @Test
    func appSwitcherIssuesEdgeTaggedSwipe() async throws {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        viewModel.appSwitcher()
        await settle()
        // App Switcher rides the edge-swipe path (system gesture), not a
        // plain touch swipe.
        #expect(fake.swipeCalls.isEmpty)
        #expect(fake.edgeSwipeCalls.count == 1)
        let call = try #require(fake.edgeSwipeCalls.first)
        #expect(call.fromX == AppSwitcherGesture.fromX)
        #expect(call.fromY == AppSwitcherGesture.fromY)
        #expect(call.toX == AppSwitcherGesture.toX)
        #expect(call.toY == AppSwitcherGesture.toY)
        #expect(call.durationMs == AppSwitcherGesture.durationMs)
        #expect(call.holdMs == AppSwitcherGesture.holdMs)
        // The bottom-edge tag is what routes it to the system gesture.
        #expect(call.edge == AppSwitcherGesture.edge)
        // The active dwell is what lands it in the switcher, not Home.
        #expect(call.holdMs > 0)
    }

    @Test
    func appSwitcherRotatesTheSwipeIntoTheCurrentOrientation() async throws {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        // Take the device to landscape, then invoke the App Switcher. The
        // gesture constants are in displayed (oriented) space; the swipe sent
        // to the daemon must be mapped into the portrait-native surface frame
        // and carry the landscape home-indicator edge, or the daemon
        // plays a portrait-bottom swipe that just pans the foreground app.
        viewModel.start()
        await settle()
        fake.lastPaneEventContinuation?.yield(
            .orientationChanged(
                OrientationChangedEvent(paneId: "p1", orientation: Orientation.landscapeLeft.rawValue)
            )
        )
        await settle()
        viewModel.appSwitcher()
        await settle()
        let call = try #require(fake.edgeSwipeCalls.last)
        let expectedFrom = SimGestureMath.rotateOrientedToSurface(
            CGPoint(x: AppSwitcherGesture.fromX, y: AppSwitcherGesture.fromY),
            orientation: .landscapeLeft
        )
        let expectedTo = SimGestureMath.rotateOrientedToSurface(
            CGPoint(x: AppSwitcherGesture.toX, y: AppSwitcherGesture.toY),
            orientation: .landscapeLeft
        )
        #expect(abs(call.fromX - Double(expectedFrom.x)) < 1e-9)
        #expect(abs(call.fromY - Double(expectedFrom.y)) < 1e-9)
        #expect(abs(call.toX - Double(expectedTo.x)) < 1e-9)
        #expect(abs(call.toY - Double(expectedTo.y)) < 1e-9)
        #expect(call.edge == AppSwitcherGesture.edge(for: .landscapeLeft))
        // The rotated swipe is genuinely different from the portrait one.
        #expect(call.edge != AppSwitcherGesture.edge)
    }

    @Test
    func appSwitcherFallsBackWholesaleToPortraitWhenNoEdge() async throws {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        // Upside-down has no home-gesture edge, so `edge(for:)` is nil. The
        // fallback must be portrait *wholesale*: the edge tag AND the
        // coordinates fall back together, so a top-origin swipe is never tagged
        // as a bottom-edge gesture. The result is byte-identical to portrait.
        viewModel.start()
        await settle()
        fake.lastPaneEventContinuation?.yield(
            .orientationChanged(
                OrientationChangedEvent(paneId: "p1", orientation: Orientation.portraitUpsideDown.rawValue)
            )
        )
        await settle()
        viewModel.appSwitcher()
        await settle()
        let call = try #require(fake.edgeSwipeCalls.last)
        #expect(call.fromX == AppSwitcherGesture.fromX)
        #expect(call.fromY == AppSwitcherGesture.fromY)
        #expect(call.toX == AppSwitcherGesture.toX)
        #expect(call.toY == AppSwitcherGesture.toY)
        #expect(call.edge == AppSwitcherGesture.edge)
    }

    @Test
    func liveTouchKeepaliveReportsHeldFingerThenStopsOnLift() async {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        // Press and hold without moving. `mouseDragged` would stop
        // firing, so without the keepalive the contact stream goes
        // silent. The keepalive re-reports the held point.
        viewModel.touch(at: CGPoint(x: 0.4, y: 0.5), phase: .down)
        try? await Task.sleep(nanoseconds: 140_000_000)  // ~4 keepalive ticks
        let heldMoves = fake.touchCalls.filter { $0.phase == .move }
        #expect(!heldMoves.isEmpty)
        // Held at (0.4, 0.5), modulo a sub-pixel anti-stall jitter on x.
        #expect(heldMoves.allSatisfy { abs($0.x - 0.4) <= 0.0015 && $0.y == 0.5 })

        // Once the finger lifts the keepalive must stop: no further
        // contact frames after the lift.
        viewModel.touch(at: CGPoint(x: 0.4, y: 0.5), phase: .lift)
        try? await Task.sleep(nanoseconds: 20_000_000)
        let countAfterLift = fake.touchCalls.count
        try? await Task.sleep(nanoseconds: 120_000_000)
        #expect(fake.touchCalls.count == countAfterLift)
    }

    @Test
    func edgeTaggedDragRoutesEveryContactToEdgeTouch() async {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        // A live bottom-edge drag: the edge is supplied on `.down` and
        // latched for the whole drag, so move + lift carry it too.
        viewModel.touch(at: CGPoint(x: 0.5, y: 0.99), phase: .down, edge: 3)
        viewModel.touch(at: CGPoint(x: 0.5, y: 0.70), phase: .move, edge: nil)
        viewModel.touch(at: CGPoint(x: 0.5, y: 0.50), phase: .lift, edge: nil)
        await settle()
        // Everything rode `pane.input.edgeTouch`, tagged with edge 3, so the
        // plain-touch path saw nothing.
        #expect(fake.touchCalls.isEmpty)
        #expect(fake.edgeTouchCalls.allSatisfy { $0.edge == 3 && $0.paneId == "p1" })
        let phases = fake.edgeTouchCalls.map(\.phase)
        #expect(phases.first == .down)
        #expect(phases.contains(.move))
        #expect(phases.last == .lift)
    }

    @Test
    func plainDragRoutesToTouchNotEdgeTouch() async {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        // No edge supplied → an ordinary touch, never edge-tagged.
        viewModel.touch(at: CGPoint(x: 0.5, y: 0.5), phase: .down, edge: nil)
        viewModel.touch(at: CGPoint(x: 0.5, y: 0.4), phase: .move, edge: nil)
        viewModel.touch(at: CGPoint(x: 0.5, y: 0.3), phase: .lift, edge: nil)
        await settle()
        #expect(fake.edgeTouchCalls.isEmpty)
        #expect(!fake.touchCalls.isEmpty)
    }

    @Test
    func keepaliveCarriesEdgeDuringHeldEdgeDrag() async {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        // Press-and-hold a bottom-edge drag: the keepalive re-reports the
        // held finger, and those resends must stay edge-tagged so the
        // dwell still reads as the system gesture (not a plain touch).
        viewModel.touch(at: CGPoint(x: 0.5, y: 0.55), phase: .down, edge: 3)
        try? await Task.sleep(nanoseconds: 140_000_000)  // ~4 keepalive ticks
        let heldMoves = fake.edgeTouchCalls.filter { $0.phase == .move }
        #expect(!heldMoves.isEmpty)
        #expect(heldMoves.allSatisfy { $0.edge == 3 })
        // The plain-touch keepalive never fires for an edge drag.
        #expect(fake.touchCalls.isEmpty)
        viewModel.touch(at: CGPoint(x: 0.5, y: 0.55), phase: .lift, edge: nil)
    }

    @Test
    func closeForwardsModeAndClearsSurface() async {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        viewModel.start()
        await settle()
        await viewModel.close(mode: .shutdown)
        #expect(fake.closePaneCalls == [.init(paneId: "p1", mode: .shutdown)])
        #expect(viewModel.currentSurface == nil)
    }

    @Test(
        "pressButton forwards the named hardware button",
        arguments: HardwareButton.allCases
    )
    func pressButtonForwardsToDaemon(_ button: HardwareButton) async {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        viewModel.pressButton(button)
        await settle()
        #expect(fake.buttonCalls == [.init(paneId: "p1", button: button)])
    }

    @Test(
        "rotate forwards the orientation without moving the pane",
        arguments: Orientation.allCases
    )
    func rotateForwardsToDaemon(_ orientation: Orientation) async {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        viewModel.rotate(to: orientation)
        await settle()
        #expect(fake.rotateCalls == [.init(paneId: "p1", target: .absolute(orientation))])
        // The command is a request, not an observation: the VM stays where it
        // is until the daemon emits `orientationChanged`.
        #expect(viewModel.currentOrientation == .portrait)
    }

    @Test
    func rotateLeftAndRightForwardTheDirectionUnresolved() async {
        // The daemon holds the orientation a relative step advances from, so
        // repeated Rotate Lefts send four identical `left` requests rather
        // than four locally-derived orientations. Deriving them here would
        // resolve against a base that stops matching the device the moment
        // anything else rotates it.
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        viewModel.rotateLeft()
        viewModel.rotateLeft()
        viewModel.rotateRight()
        await settle()
        #expect(fake.rotateCalls.map(\.target) == [
            .relative(.left),
            .relative(.left),
            .relative(.right)
        ])
        #expect(viewModel.currentOrientation == .portrait)
    }

    @Test(
        "the orientation event is the only writer of tracked orientation",
        arguments: Orientation.allCases
    )
    func orientationChangedEventDrivesTrackedOrientation(_ orientation: Orientation) async {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        viewModel.start()
        await settle()
        fake.lastPaneEventContinuation?.yield(
            .orientationChanged(
                OrientationChangedEvent(paneId: "p1", orientation: orientation.rawValue)
            )
        )
        await settle()
        #expect(viewModel.currentOrientation == orientation)
    }

    @Test
    func anUnknownOrientationEventIsIgnored() async {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        viewModel.start()
        await settle()
        fake.lastPaneEventContinuation?.yield(
            .orientationChanged(OrientationChangedEvent(paneId: "p1", orientation: "sideways"))
        )
        await settle()
        #expect(viewModel.currentOrientation == .portrait)
    }

    @Test
    func crownForwardsDeltaToDaemon() async {
        // The VM stays device-agnostic: the watchOS gate lives in
        // the VC. The VM just forwards. durationMs is hard-coded to
        // 0 (one-shot) so each scroll-wheel detent is its own crown
        // update; sub-step pacing is the daemon's job.
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        viewModel.crown(delta: 3.5)
        await settle()
        #expect(fake.crownCalls.count == 1)
        #expect(fake.crownCalls.first?.paneId == "p1")
        #expect(fake.crownCalls.first?.delta == 3.5)
        #expect(fake.crownCalls.first?.durationMs == 0)
    }

    @Test
    func defaultCapabilitiesAllowRotateAndCrown() async {
        // No capabilities passed → resolves to `.simulator`, so the
        // historical all-enabled behavior holds.
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake)
        viewModel.rotate(to: .landscapeLeft)
        viewModel.crown(delta: 1)
        await settle()
        #expect(fake.rotateCalls.count == 1)
        #expect(fake.crownCalls.count == 1)
    }

    @Test
    func paneCapabilitiesSuppressUnsupportedInput() async {
        // A physical-device capability set: no rotate, no crown, no
        // keyboard. The VM must not forward those verbs, since it backs a
        // device pane that would reject them.
        var caps = PaneCapabilities.simulator
        caps.rotate = false
        caps.crown = false
        caps.key = false
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake, capabilities: caps)
        viewModel.rotate(to: .landscapeLeft)
        viewModel.rotateLeft()
        viewModel.crown(delta: 1)
        viewModel.keyDown(keyCode: 0)
        await settle()
        // The relative form goes through the same gate as the absolute one.
        #expect(fake.rotateCalls.isEmpty)
        #expect(fake.crownCalls.isEmpty)
        #expect(!fake.paneInputCalls.contains { $0.0 == .paneInputKey })
    }

    @Test
    func resubscribesAfterConnectionDropsMidStream() async {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake, reconnectBackoffNs: 1_000_000)  // 1ms
        viewModel.start()
        await settle()
        // Reach a non-terminal state so a stream-end reads as a drop.
        fake.lastPaneEventContinuation?.yield(
            .stateChanged(StateChangedEvent(paneId: "p1", state: .rendering))
        )
        await settle()
        #expect(fake.subscribePaneCalls == ["p1"])

        // Simulate the daemon connection dropping: the stream ends.
        fake.lastPaneEventContinuation?.finish()
        // Wait for the resubscribe rather than a fixed sleep.
        #expect(await poll { fake.subscribePaneCalls == ["p1", "p1"] })
    }

    @Test
    func retriesSubscribeAfterTransientTransportFailure() async {
        let fake = FakeDaemonClient()
        // First subscribe throws a transport drop; the loop backs off and
        // retries rather than failing the pane.
        fake.subscribePaneFailures = [DaemonClientError.transport("connection closed")]
        let viewModel = makeViewModel(fake, reconnectBackoffNs: 1_000_000)  // 1ms
        viewModel.start()
        // Subscribed twice (fail, then retry succeeds); wait for the retry.
        #expect(await poll { fake.subscribePaneCalls == ["p1", "p1"] })
        // The pane is not marked failed.
        if case .failed = viewModel.state {
            Issue.record("transient transport failure must not fail the pane")
        }
    }

    @Test
    func failsPaneOnTerminalDaemonSubscribeError() async {
        let fake = FakeDaemonClient()
        // A daemon response (pane-not-found) is terminal: fail, don't retry.
        fake.subscribePaneFailures = [
            DaemonClientError.daemon(code: -32_004, message: "pane not found")
        ]
        let viewModel = makeViewModel(fake, reconnectBackoffNs: 1_000_000)  // 1ms
        viewModel.start()
        // Wait for the terminal transition (no backoff on this path).
        #expect(await poll {
            if case .failed = viewModel.state { return true }
            return false
        })
        // Only one attempt.
        #expect(fake.subscribePaneCalls == ["p1"])
    }

    @Test
    func doesNotResubscribeAfterTerminalState() async {
        let fake = FakeDaemonClient()
        let viewModel = makeViewModel(fake, reconnectBackoffNs: 1_000_000)  // 1ms
        viewModel.start()
        await settle()
        // A terminal (shutdown) state means the pane is deliberately gone.
        fake.lastPaneEventContinuation?.yield(
            .stateChanged(StateChangedEvent(paneId: "p1", state: .shutdown))
        )
        // Wait until the shutdown is processed (positive signal), then end
        // the stream.
        #expect(await poll { viewModel.state == .shutdown })
        fake.lastPaneEventContinuation?.finish()
        // With a 1ms backoff, a would-be retry fires near-instantly. Give it
        // a bounded window to prove it never resubscribes.
        let retried = await poll(maxIterations: 100) {  // ~200ms
            fake.subscribePaneCalls.count > 1
        }
        #expect(!retried)
        #expect(fake.subscribePaneCalls == ["p1"])
    }
}
