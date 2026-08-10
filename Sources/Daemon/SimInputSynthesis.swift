// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimInputSynthesis: the pure input-synthesis half of `PaneCoordinator`.
//
// Every `pane.input.*` gesture is coordinate/timing math plus synchronous
// `DeviceBackend` HID sends; none of it touches `PaneCoordinator`'s mutable
// pane state. The coordinator resolves the backend (its one stateful step,
// `requireBackend`), then hands it here. These statics take a resolved
// `any DeviceBackend` (Sendable) and are `nonisolated`, so the gesture's
// `Task.sleep` pacing runs off the actor, the same isolation the actor
// already released at every `await` before the seam.
//
// The one gesture with a state side effect stays on the actor: `rotate`
// here does only the backend call; the coordinator fans the
// `.orientationChanged` event out to subscribers.

import CoreGraphics
import DaemonProtocol
import Foundation

enum SimInputSynthesis {
    /// Coarse re-report cadence (~30 Hz) for an active dwell. See
    /// `activeDwell`.
    static let dwellReportIntervalMs: Int = 33

    /// Sub-pixel nudge applied to each dwell frame so the synchronous
    /// CoreSimulator HID send's completion semaphore fires, because an
    /// identical-point resend never completes and stalls the gesture.
    /// Far below the recognizer's movement threshold, so the finger
    /// still reads as held-still.
    static let dwellJitter: Double = 0.001

    /// Gap between the two consumer-HID Home presses of the App Switcher
    /// fallback, inside iOS's double-press window.
    static let appSwitcherDoublePressGapNs: UInt64 = 200_000_000

    static func tap(backend: any DeviceBackend, paneId: UUID, generation: UInt64, x: Double, y: Double) throws {
        let point = CGPoint(x: x, y: y)
        do {
            try backend.tapDown(at: point, generation: generation)
            try backend.tapUp(at: point, generation: generation)
        } catch {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .tap,
                message: BridgeMessage.unwrap(error)
            )
        }
    }

    /// Live single-finger contact update. `down` starts contact,
    /// `move` continues contact at a new position, and `up` releases
    /// at the final position. This is the direct-manipulation path
    /// used by the GUI; scripted `swipe` remains interpolated.
    static func touch(
        backend: any DeviceBackend,
        paneId: UUID,
        generation: UInt64,
        x: Double,
        y: Double,
        phase: TouchPhase
    ) throws {
        let point = CGPoint(x: x, y: y)
        do {
            switch phase {
            case .down, .move:
                try backend.tapDown(at: point, generation: generation)

            case .lift:
                try backend.tapUp(at: point, generation: generation)
            }
        } catch {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .touch,
                message: BridgeMessage.unwrap(error)
            )
        }
    }

    /// Live single-finger **edge-tagged** contact update, the per-event
    /// analogue of `touch` for the system gestures. A live GUI mouse drag
    /// starting in the displayed bottom-edge band streams these so the home
    /// indicator / App Switcher follows the cursor, where the scripted
    /// `edgeSwipe` plays a fixed trajectory. Unlike plain `touch` (which
    /// collapses `.down`/`.move` to `tapDown`), each phase maps to its own
    /// primitive: the per-phase `NSEventType` (down/dragged/up) is exactly
    /// what routes the contact to SpringBoard's edge-gesture recognizer.
    /// `edge` is the raw `IndigoHIDEdge` value (used by the simulator; the
    /// physical device routes via the system-gesture report trailer and
    /// ignores it). A backend with no edge path throws `unsupportedEdgeGesture`,
    /// mapped to `unsupportedOperation`.
    static func edgeTouch(
        backend: any DeviceBackend,
        paneId: UUID,
        generation: UInt64,
        x: Double,
        y: Double,
        phase: TouchPhase,
        edge: Int
    ) throws {
        let point = CGPoint(x: x, y: y)
        do {
            switch phase {
            case .down:
                try backend.edgeTouchDown(at: point, edge: edge, generation: generation)

            case .move:
                try backend.edgeTouchMove(at: point, edge: edge, generation: generation)

            case .lift:
                try backend.edgeTouchUp(at: point, edge: edge, generation: generation)
            }
        } catch let error as DeviceBackendError {
            throw PaneError.mapBackendError(error, paneId: paneId, operation: .edgeTouch)
        } catch {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .edgeTouch,
                message: BridgeMessage.unwrap(error)
            )
        }
    }

    /// Linear interpolation between `(fromX, fromY)` and `(toX, toY)`
    /// over `durationMs` milliseconds at ~60 Hz. `tapDown` at the
    /// start, doubled-payload `tapDown` at each intermediate step
    /// (the Indigo digitizer treats successive downs as continued
    /// contact), then an optional `holdMs` **active dwell** at the end
    /// point, then `tapUp`. Returns the `SwipeOutcome` so the daemon
    /// handler can report whether the gesture actually interpolated
    /// (`drag`) or collapsed to a single down/up (`tap`, caller's
    /// `durationMs` was below the one-frame floor).
    ///
    /// The dwell re-reports `tapDown` at the end point every frame for
    /// `holdMs`, *not* a single passive `Task.sleep` like `longPress`.
    /// That continuous "still in contact, velocity ~0" stream is what
    /// the iOS app-switcher recognizer needs to distinguish a deliberate
    /// swipe-up-and-pause from a fast swipe-to-Home. `holdMs == 0` skips
    /// the dwell entirely, leaving the no-hold wire byte-identical to a
    /// plain swipe.
    static func swipe(
        backend: any DeviceBackend,
        paneId: UUID,
        generation: UInt64,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        durationMs: Int,
        holdMs: Int = 0,
        startHoldMs: Int = 0
    ) async throws -> PaneCoordinator.SwipeOutcome {
        let timing = GestureTiming(durationMs: durationMs, maxMs: PaneCoordinator.maxGestureDurationMs)
        let deltaX = (toX - fromX) / Double(timing.steps)
        let deltaY = (toY - fromY) / Double(timing.steps)
        let start = CGPoint(x: fromX, y: fromY)
        let end = CGPoint(x: toX, y: toY)
        // `generation` is the operation token the coordinator captured at
        // admission (atomically with the ownership gate). Each paced step
        // re-checks it and every send carries it; a transfer bumps it, so
        // the gesture stops and its later sends are dropped. Held contacts
        // are released by the backend quiesce, not here.
        do {
            try backend.tapDown(at: start, generation: generation)
            // Active dwell at the origin before moving, which lets the OS lock
            // onto a bottom-edge system gesture before the drag. Skipped
            // when startHoldMs is 0 so a plain swipe is unchanged.
            try await activeDwell(backend: backend, at: start, holdMs: startHoldMs, generation: generation)
            for step in 1...timing.steps {
                try? await Task.sleep(nanoseconds: timing.stepDurationNs)
                guard backend.isInputGenerationCurrent(generation) else {
                    return PaneCoordinator.SwipeOutcome(steps: timing.steps, durationMs: timing.totalMs)
                }
                let next = CGPoint(x: fromX + deltaX * Double(step), y: fromY + deltaY * Double(step))
                try backend.tapDown(at: next, generation: generation)
            }
            // Active dwell at the end point so the OS sees the finger stop
            // while still down. Skipped when holdMs is 0.
            try await activeDwell(backend: backend, at: end, holdMs: holdMs, generation: generation)
            try backend.tapUp(at: end, generation: generation)
        } catch {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .swipe,
                message: BridgeMessage.unwrap(error)
            )
        }
        return PaneCoordinator.SwipeOutcome(steps: timing.steps, durationMs: timing.totalMs)
    }

    /// Edge-tagged drag: an interpolated swipe whose contacts carry the
    /// originating screen `edge` (raw `IndigoHIDEdge`), so iOS routes it
    /// to the system gesture recognizer (home indicator / App Switcher)
    /// rather than app content. Down → `MouseDragged` samples → optional
    /// active dwell → up, all edge-tagged. Sim-only (other backends throw
    /// `unsupportedEdgeGesture`).
    static func edgeSwipe(
        backend: any DeviceBackend,
        paneId: UUID,
        generation: UInt64,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        edge: Int,
        durationMs: Int,
        holdMs: Int
    ) async throws {
        // A physical device can't route a synthesized edge-tagged COORDINATE
        // touch to SpringBoard's system-gesture recognizer. Its digitizer
        // report reaches the foreground app, not the gesture manager, so a
        // coordinate swipe just scrolls. Realize the App Switcher through the
        // system-gesture touch swipe instead (enriched touch reports that the
        // home-indicator recognizer consumes), falling back to a consumer-HID
        // Home double-press on any backend that doesn't implement it. The swipe
        // coordinates apply to the simulator path only.
        guard backend.supportsSystemEdgeGesture else {
            try await appSwitcherOnDevice(backend: backend, paneId: paneId, generation: generation, edge: edge)
            return
        }
        let timing = GestureTiming(durationMs: durationMs, maxMs: PaneCoordinator.maxGestureDurationMs)
        let deltaX = (toX - fromX) / Double(timing.steps)
        let deltaY = (toY - fromY) / Double(timing.steps)
        let end = CGPoint(x: toX, y: toY)
        do {
            try backend.edgeTouchDown(at: CGPoint(x: fromX, y: fromY), edge: edge, generation: generation)
            for step in 1...timing.steps {
                try? await Task.sleep(nanoseconds: timing.stepDurationNs)
                guard backend.isInputGenerationCurrent(generation) else { return }
                let next = CGPoint(x: fromX + deltaX * Double(step), y: fromY + deltaY * Double(step))
                try backend.edgeTouchMove(at: next, edge: edge, generation: generation)
            }
            if holdMs > 0 {
                let capped = min(max(holdMs, 0), PaneCoordinator.maxGestureDurationMs)
                let frames = max(1, capped / Self.dwellReportIntervalMs)
                let stepNs = UInt64(Self.dwellReportIntervalMs) * 1_000_000
                for frame in 1...frames {
                    try? await Task.sleep(nanoseconds: stepNs)
                    guard backend.isInputGenerationCurrent(generation) else { return }
                    let jitter = frame.isMultiple(of: 2) ? Self.dwellJitter : -Self.dwellJitter
                    let dwellPoint = CGPoint(x: end.x + jitter, y: end.y)
                    try backend.edgeTouchMove(at: dwellPoint, edge: edge, generation: generation)
                }
            }
            try backend.edgeTouchUp(at: end, edge: edge, generation: generation)
        } catch {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .edgeSwipe,
                message: BridgeMessage.unwrap(error)
            )
        }
    }

    /// Open the App Switcher on a backend that can't drive the touch-based
    /// system gesture (a physical device): prefer the real swipe gesture
    /// (`openAppSwitcher`), and fall back to the Home double-press only if the
    /// backend doesn't implement it (`unsupportedEdgeGesture`). Any other
    /// failure from the gesture path surfaces as a bridge error.
    private static func appSwitcherOnDevice(
        backend: any DeviceBackend,
        paneId: UUID,
        generation: UInt64,
        edge: Int
    ) async throws {
        do {
            try backend.openAppSwitcher(edge: edge, generation: generation)
        } catch DeviceBackendError.unsupportedEdgeGesture {
            try await appSwitcherViaHomeDoublePress(backend: backend, paneId: paneId, generation: generation)
        } catch {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .edgeSwipe,
                message: BridgeMessage.unwrap(error)
            )
        }
    }

    /// Open the App Switcher on a backend that can't drive the touch-based
    /// system gesture (a physical device) by double-pressing the consumer-HID
    /// Home usage, the same event a hardware double-press sends, which iOS
    /// routes to the App Switcher. The gap between presses must fall inside
    /// iOS's double-press window; the two enqueues land ~`gap` apart and the
    /// device sees them well within it.
    private static func appSwitcherViaHomeDoublePress(
        backend: any DeviceBackend,
        paneId: UUID,
        generation: UInt64
    ) async throws {
        do {
            try backend.pressHardwareButton(.home, generation: generation)
            try await Task.sleep(nanoseconds: Self.appSwitcherDoublePressGapNs)
            // The gap is an `await`; a transfer can land in it. Stop before
            // the second press rather than driving the new owner's device.
            guard backend.isInputGenerationCurrent(generation) else { return }
            try backend.pressHardwareButton(.home, generation: generation)
        } catch {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .edgeSwipe,
                message: BridgeMessage.unwrap(error)
            )
        }
    }

    /// Hold a finger at `point` for `holdMs` by re-reporting contact at a
    /// coarse cadence. A no-op when `holdMs <= 0`.
    ///
    /// Each frame is nudged a sub-pixel amount off `point` (alternating
    /// sign) for two reasons: (1) the synchronous CoreSimulator HID send
    /// waits on a completion semaphore that an *identical*-point resend
    /// never fires (it stalls the full 1s timeout, ballooning the
    /// gesture and breaking its timing), and (2) the jitter is far below
    /// the recognizer's movement threshold, so the finger still reads as
    /// held-still. Throws via the caller's `do/catch` (the backend send
    /// can fail); callers wrap it in the same bridge-error mapping as the
    /// surrounding gesture.
    private static func activeDwell(
        backend: any DeviceBackend,
        at point: CGPoint,
        holdMs: Int,
        generation: UInt64
    ) async throws {
        guard holdMs > 0 else { return }
        let capped = min(max(holdMs, 0), PaneCoordinator.maxGestureDurationMs)
        let frames = max(1, capped / Self.dwellReportIntervalMs)
        let stepNs = UInt64(Self.dwellReportIntervalMs) * 1_000_000
        for frame in 1...frames {
            try? await Task.sleep(nanoseconds: stepNs)
            // Stop dwelling on a transfer; the backend quiesce releases the
            // held contact.
            guard backend.isInputGenerationCurrent(generation) else { return }
            let jitter = frame.isMultiple(of: 2) ? Self.dwellJitter : -Self.dwellJitter
            try backend.tapDown(at: CGPoint(x: point.x + jitter, y: point.y), generation: generation)
        }
    }

    static func longPress(
        backend: any DeviceBackend,
        paneId: UUID,
        generation: UInt64,
        x: Double,
        y: Double,
        durationMs: Int
    ) async throws {
        let point = CGPoint(x: x, y: y)
        // Clamp before the ms→ns cast. See `swipe` for the same
        // overflow rationale.
        let cappedMs = min(max(durationMs, 0), PaneCoordinator.maxGestureDurationMs)
        do {
            try backend.tapDown(at: point, generation: generation)
            // Poll the hold rather than one long sleep, so a transfer stops
            // it promptly (the backend quiesce releases the held contact)
            // instead of holding for up to the 60s cap.
            var elapsedMs = 0
            while elapsedMs < cappedMs {
                let chunkMs = min(Self.dwellReportIntervalMs, cappedMs - elapsedMs)
                try? await Task.sleep(nanoseconds: UInt64(chunkMs) * 1_000_000)
                elapsedMs += chunkMs
                guard backend.isInputGenerationCurrent(generation) else { break }
            }
            try backend.tapUp(at: point, generation: generation)
        } catch {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .longPress,
                message: BridgeMessage.unwrap(error)
            )
        }
    }

    static func key(backend: any DeviceBackend, paneId: UUID, generation: UInt64, keyCode: UInt32, down: Bool) throws {
        // Wire value is the kVK virtual key from `NSEvent.keyCode`;
        // Indigo expects HID usage codes. Translation is the
        // daemon's job. Without it, every key is gibberish.
        guard let hid = KeyboardInputMap.kVKToHIDUsage(keyCode) else {
            throw PaneError.unsupportedKeyCode(paneId: paneId, keyCode: keyCode)
        }
        do {
            if down {
                try backend.keyDown(hidUsage: hid, generation: generation)
            } else {
                try backend.keyUp(hidUsage: hid, generation: generation)
            }
        } catch {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .key(down: down),
                message: BridgeMessage.unwrap(error)
            )
        }
    }

    static func pressButton(
        backend: any DeviceBackend,
        paneId: UUID,
        generation: UInt64,
        button: HardwareButton
    ) throws {
        do {
            try backend.pressHardwareButton(button, generation: generation)
        } catch {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .button(button),
                message: BridgeMessage.unwrap(error)
            )
        }
    }

    /// Two-finger interpolated gesture. Linear path for each finger
    /// from its `from` point to its `to` point at ~60Hz. Indigo's
    /// digitizer treats successive `twoFingerDown` calls at new
    /// positions as continued contact (same shape as `swipe`).
    static func pinch(
        backend: any DeviceBackend,
        paneId: UUID,
        generation: UInt64,
        fromF1X: Double,
        fromF1Y: Double,
        fromF2X: Double,
        fromF2Y: Double,
        toF1X: Double,
        toF1Y: Double,
        toF2X: Double,
        toF2Y: Double,
        durationMs: Int
    ) async throws {
        let timing = GestureTiming(durationMs: durationMs, maxMs: PaneCoordinator.maxGestureDurationMs)
        let deltaF1X = (toF1X - fromF1X) / Double(timing.steps)
        let deltaF1Y = (toF1Y - fromF1Y) / Double(timing.steps)
        let deltaF2X = (toF2X - fromF2X) / Double(timing.steps)
        let deltaF2Y = (toF2Y - fromF2Y) / Double(timing.steps)
        do {
            try backend.twoFingerDown(
                f1: CGPoint(x: fromF1X, y: fromF1Y),
                f2: CGPoint(x: fromF2X, y: fromF2Y),
                generation: generation
            )
            for step in 1...timing.steps {
                try? await Task.sleep(nanoseconds: timing.stepDurationNs)
                guard backend.isInputGenerationCurrent(generation) else { return }
                let finger1 = CGPoint(
                    x: fromF1X + deltaF1X * Double(step),
                    y: fromF1Y + deltaF1Y * Double(step)
                )
                let finger2 = CGPoint(
                    x: fromF2X + deltaF2X * Double(step),
                    y: fromF2Y + deltaF2Y * Double(step)
                )
                try backend.twoFingerDown(f1: finger1, f2: finger2, generation: generation)
            }
            try backend.twoFingerUp(
                f1: CGPoint(x: toF1X, y: toF1Y),
                f2: CGPoint(x: toF2X, y: toF2Y),
                generation: generation
            )
        } catch {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .pinch,
                message: BridgeMessage.unwrap(error)
            )
        }
    }

    /// Live two-finger contact update, the interactive counterpart to
    /// the interpolated `pinch`. `down` starts both contacts, `move`
    /// continues them at new positions (the Indigo digitizer treats
    /// successive `twoFingerDown` calls as continued contact), `up`
    /// releases. The caller streams frames as the gesture changes; there
    /// is no daemon-side interpolation. `points` is exactly two contacts,
    /// ordered finger 1, finger 2.
    static func multitouch(
        backend: any DeviceBackend,
        paneId: UUID,
        generation: UInt64,
        phase: TouchPhase,
        points: [CGPoint]
    ) throws {
        guard points.count == 2 else {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .multitouch,
                message: "exactly 2 contact points required, got \(points.count)"
            )
        }
        do {
            switch phase {
            case .down, .move:
                try backend.twoFingerDown(f1: points[0], f2: points[1], generation: generation)

            case .lift:
                try backend.twoFingerUp(f1: points[0], f2: points[1], generation: generation)
            }
        } catch {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .multitouch,
                message: BridgeMessage.unwrap(error)
            )
        }
    }

    /// Type an ASCII string into the focused field. Each character
    /// translates to a kVK key code (with Shift held when needed).
    /// Unknown characters throw `unsupportedCharacter`. The caller
    /// is responsible for filtering or splitting around them rather
    /// than the daemon silently dropping input.
    ///
    /// The whole string is validated against the keymap *before*
    /// any HID event is sent. Without that, "abcé" would type
    /// "abc" and then throw on `é`, partially mutating the focused
    /// field even though the caller sees an error.
    static func text(backend: any DeviceBackend, paneId: UUID, generation: UInt64, text: String) throws {
        for character in text where KeyboardInputMap.asciiKeyMap[character] == nil {
            throw PaneError.unsupportedCharacter(
                paneId: paneId,
                character: character
            )
        }
        for character in text {
            // Already proven non-nil by the validation pass above.
            guard let mapping = KeyboardInputMap.asciiKeyMap[character] else { continue }
            do {
                if mapping.shift {
                    try backend.keyDown(hidUsage: KeyboardInputMap.hidShift, generation: generation)
                    // Inner do-catch handles the Shift release on
                    // both paths:
                    //   - success: release Shift with `try`, so a
                    //     genuine release failure surfaces to the
                    //     caller instead of being swallowed.
                    //   - character throw: best-effort release Shift
                    //     (try?) so it doesn't get stuck in the sim's
                    //     modifier state, then propagate the original
                    //     error rather than masking it with a release
                    //     failure.
                    do {
                        try backend.keyDown(hidUsage: mapping.keyCode, generation: generation)
                        try backend.keyUp(hidUsage: mapping.keyCode, generation: generation)
                        try backend.keyUp(hidUsage: KeyboardInputMap.hidShift, generation: generation)
                    } catch {
                        try? backend.keyUp(hidUsage: KeyboardInputMap.hidShift, generation: generation)
                        throw error
                    }
                } else {
                    try backend.keyDown(hidUsage: mapping.keyCode, generation: generation)
                    try backend.keyUp(hidUsage: mapping.keyCode, generation: generation)
                }
            } catch {
                throw PaneError.bridgeFailed(
                    paneId: paneId,
                    operation: .text,
                    message: BridgeMessage.unwrap(error)
                )
            }
        }
    }

    /// Drive the backend rotation only. The coordinator fans the
    /// resulting `.orientationChanged` event out to subscribers, which
    /// touches pane state and stays on the actor.
    static func rotate(
        backend: any DeviceBackend,
        paneId: UUID,
        generation: UInt64,
        orientation: Orientation
    ) async throws -> Bool {
        do {
            return try await backend.rotate(to: orientation, generation: generation)
        } catch {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .rotate,
                message: BridgeMessage.unwrap(error)
            )
        }
    }

    /// Rotate the watchOS Digital Crown by a signed `delta` (sign =
    /// direction, magnitude = distance). `durationMs == 0` sends the whole
    /// rotation at once; a positive duration sub-steps it over the duration
    /// at ~60Hz for a smooth scroll (same shape as `swipe`). `velocity` is
    /// accepted at the RPC layer but ignored here: the bridge builder takes
    /// only a delta.
    ///
    /// **Empirical note.** On tight SwiftUI Float bindings like
    /// `.digitalCrownRotation(in: 0...1, by: 0.005, sensitivity:
    /// .medium)`, the streaming `durationMs > 0` path silently no-ops
    /// when per-event delta (`delta / steps`) falls below the watchOS
    /// recognizer's coalescing floor (between 0.97 and 1.08
    /// IndigoWheel units in the recorded configuration at ~60Hz cadence).
    /// The single-shot path is
    /// unaffected: a lone event of magnitude 1.0 still registers as
    /// ~0.18 of the binding's range. High-total saturation
    /// (`delta=100` → binding clamps to range max) is platform-level
    /// regardless of pacing. Documented in
    /// `Tests/Manual/watchos-checklist.md` under "Crown Response
    /// With a Tight SwiftUI Binding"; `deviceterm agents`
    /// carries the user-facing recommendation (use single-shot for
    /// fine placement on tight Float bindings).
    static func crown(
        backend: any DeviceBackend,
        paneId: UUID,
        generation: UInt64,
        delta: Double,
        durationMs: Int
    ) async throws {
        do {
            if durationMs <= 0 {
                try backend.rotateCrown(delta: delta, generation: generation)
                return
            }
            let timing = GestureTiming(durationMs: durationMs, maxMs: PaneCoordinator.maxGestureDurationMs)
            let step = delta / Double(timing.steps)
            for index in 1...timing.steps {
                // Crown deltas are discrete (no held contact to release), so
                // a transfer just stops the remaining steps.
                guard backend.isInputGenerationCurrent(generation) else { return }
                try backend.rotateCrown(delta: step, generation: generation)
                if index < timing.steps {
                    try? await Task.sleep(nanoseconds: timing.stepDurationNs)
                }
            }
        } catch {
            throw PaneError.bridgeFailed(
                paneId: paneId,
                operation: .crown,
                message: BridgeMessage.unwrap(error)
            )
        }
    }
}
