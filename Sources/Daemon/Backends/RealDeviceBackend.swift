// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreVideo
import DaemonProtocol
import Foundation
import InteractionRelay
import IOSurface
import MirrorPipeline
import os
import SurfaceTrace

// The touch and key witnesses are `throws` (the protocol requires it) but only
// enqueue, so they never throw; the unneeded-throws rule is a false positive on
// them. The unsupported verbs under the same suppression do throw.
// swiftlint:disable unneeded_throws_rethrows
/// `DeviceBackend` over the physical-device pipeline,
/// driving a physically-connected iPhone/iPad.
///
/// Frames: a `DecodedFrameFeed` (the `MirrorPipeline`) yields decoded pixel
/// buffers; each is copied into a `LeasedSurfacePool` slot before it's handed to
/// subscribers, so they read a snapshot VideoToolbox can't recycle out from under
/// them, and the slot is reused only once every hold on it is released (see
/// `LeasedSurfacePool`). The feed never publishes its own surface: the daemon
/// owns the pool, the copy, the trace, and the publish.
///
/// Input: an `InteractionRelaying` (the `InteractionRelay`) delivers typed
/// intents. The touch, key, and button witnesses enqueue and return rather
/// than awaiting the relay, even though `DeviceBackend` declares them
/// `async throws`: each enqueues onto a per-surface stream and a serial pump
/// drains it into `device.perform(...)`. Rotation and location await their
/// command outcome instead. The device only *routes*
/// touch/keyboard once a media stream holds its auth gate open (which
/// `startFrames` establishes) so the gated pumps wait for the first decoded
/// frame; input enqueued meanwhile buffers and drains once it opens. Buttons and
/// rotation need no stream, so their pumps run ungated.
///
/// `@unchecked Sendable`: it holds non-Sendable pipeline handles, but only the
/// owning `PaneCoordinator` actor calls into it, and the frame/input work runs on
/// tasks that don't touch coordinator state.
final class RealDeviceBackend: DeviceBackend, @unchecked Sendable {
    /// One hardware-button press: the control plus how long the daemon holds it
    /// down before releasing. The relay resolves the control's HID usage.
    struct ButtonPress: Equatable, Sendable {
        let control: ButtonInput.Control
        let holdNanos: UInt64
    }

    /// A keyboard key transition (HID Keyboard usage, page 0x07).
    private enum KeyCommand: Sendable {
        case down(UInt16)
        // swiftlint:disable:next identifier_name
        case up(UInt16)
    }

    /// A rotation enqueued on the rotation pump: the target orientation plus a
    /// completion the pump resumes with this specific command's outcome:
    /// `true` iff it was performed and the device reached the target, `false`
    /// if a transfer fenced it or it never reached the target. Lets the
    /// awaiting `rotate` caller report a per-command result, not a
    /// generation-wide guess.
    private struct RotationRequest: Sendable {
        let orientation: Orientation
        let completion: @Sendable (Bool) -> Void
    }

    /// One location mutation on the location pump. Carries a completion
    /// so the awaiting caller learns *its* command's outcome, including
    /// the error `devicectl` reported, rather than a generation-wide
    /// guess.
    private struct LocationRequest: Sendable {
        let command: LocationCommand
        let completion: @Sendable (Result<Void, any Error>) -> Void
    }

    /// A location mutation. Reads (`availableLocationScenarios`) do not
    /// ride the pump: they mutate nothing, so they need neither the
    /// ordering nor the transfer fence.
    private enum LocationCommand: Sendable {
        case coordinate(latitude: Double, longitude: Double)
        case scenario(String)
        case route(RouteSpec)
        case clear
    }

    /// The input state held at transfer time, **snapshotted (not cleared)**
    /// under `inputGate`, then released by quiesce, which clears each item
    /// only once its release actually lands (a failed release stays held).
    private struct HeldSnapshot {
        let touch: TouchInput?
        let keys: Set<UInt16>
        let buttons: [ButtonInput.Control]
    }

    /// One item on an input pump. `perform` carries the input plus the
    /// **input generation** captured when the verb was admitted: the pump
    /// drops it if that generation is no longer current (an ownership
    /// transfer invalidated it), so a prior owner's buffered command can't
    /// execute against the new owner. `barrier` is the ownership-transfer
    /// fence: when the pump reaches it, every prior item has been processed
    /// (performed or dropped) and no perform is in flight, so `signal`
    /// resolves the quiesce's no-further-send wait.
    private enum PumpItem<Value: Sendable>: Sendable {
        case perform(generation: UInt64, Value)
        case barrier(@Sendable () -> Void)
    }

    /// One item of human input, plus an optional completion for a caller that
    /// awaits its own work. Only the human-input pump carries one, so the
    /// completion rides the payload rather than widening `PumpItem` for the
    /// four pumps that never use it.
    ///
    /// `completion` fires once the work has been performed *or* dropped as
    /// stale, so an awaiting caller is never stranded.
    private struct HumanInputWork: @unchecked Sendable {
        let input: TouchInput
        /// Fires when the pump dequeues the work and is about to perform it, so
        /// an awaiting caller can stop timing out on admission. Execution takes
        /// as long as it takes.
        let onStart: (@Sendable () -> Void)?
        let completion: (@Sendable () -> Void)?

        init(
            _ input: TouchInput,
            onStart: (@Sendable () -> Void)? = nil,
            completion: (@Sendable () -> Void)? = nil
        ) {
            self.input = input
            self.onStart = onStart
            self.completion = completion
        }
    }

    /// An App Switcher macro in flight. Its continuation resumes exactly once,
    /// whichever of the four exits happens first: the macro finished, it was
    /// cancelled, its generation went stale, or the pump's stream ended.
    private final class AppSwitcherRequest: @unchecked Sendable {
        let cancellation: InteractionCancellation
        /// The completion and the deadline race to finish this request, so the
        /// exactly-once check needs its own isolation: resuming a checked
        /// continuation twice traps.
        private let lock = DispatchQueue(label: "com.deviceterm.device.app-switcher-request")
        private var resumed = false
        private var continuation: CheckedContinuation<Void, Never>?

        init(cancellation: InteractionCancellation) {
            self.cancellation = cancellation
        }

        /// Park the caller, unless this request already finished.
        func install(_ continuation: CheckedContinuation<Void, Never>) {
            let alreadyDone = lock.sync { () -> Bool in
                if resumed { return true }
                self.continuation = continuation
                return false
            }
            if alreadyDone { continuation.resume() }
        }

        func finish() {
            let waiting = lock.sync { () -> CheckedContinuation<Void, Never>? in
                guard !resumed else { return nil }
                resumed = true
                let pending = continuation
                continuation = nil
                return pending
            }
            waiting?.resume()
        }
    }

    /// Probe every Nth frame for the content rect until it locks. A content-full
    /// frame normally locks on the first frame; throttling means a stream that
    /// can't be sized *yet* (asleep device / black launch screen) or *ever*
    /// (padding beyond the trim cap) keeps retrying without rescanning every
    /// frame.
    private static let paddingDetectionInterval = 60
    /// Default device-surface pool slot count when unset.
    static let defaultPoolSlots = 6
    /// How often the delinquency watchdog samples the pool.
    private static let watchdogIntervalNanoseconds: UInt64 = 2_000_000_000
    /// Consecutive exhaustion drops that trigger a controlled pool recovery
    /// (~2s at 60fps).
    private static let exhaustionRecoveryThreshold = 120
    /// How much frame history one metrics summary covers.
    private static let metricsWindowNanoseconds: UInt64 = 1_000_000_000
    /// How long an App Switcher request waits for the human-input pump to pick
    /// it up before giving up.
    ///
    /// The pump is gated on the device's first decoded frame, so a device that
    /// never streams would otherwise park the caller forever. Matched to the
    /// contact lane's own abandonment bound: past a couple of seconds, whatever
    /// is holding the digitizer is not coming back.
    private static let appSwitcherAdmissionTimeoutNanos: UInt64 = 2_000_000_000

    private let feed: any DecodedFrameFeed
    private let device: any InteractionRelaying
    /// CoreDevice identifier, passed to `devicectl --device`. Location is
    /// the only surface that needs it: everything else rides the relay's
    /// already-established channels.
    private let deviceId: String
    private let location: any DeviceLocationSimulating
    private let onDiagnostic: (@Sendable (String) -> Void)?
    private let pool: LeasedSurfacePool
    /// Off-by-default frame measurement. Non-nil is the on switch: the frame
    /// task reads no clocks and builds no accumulator without it.
    private let metricsSink: FrameMetricsSink?
    /// Copy intervals for Instruments, `.disabled` unless metrics are on.
    private let signposter: OSSignposter
    // Fences frame/fatal callback eligibility against teardown. `startFrames`
    // captures the current `frameToken`; teardown bumps it (both under
    // `frameGate`). A callback fires only while its captured token is still
    // current, so no publish or fatal escapes after stop, with no
    // check-then-act window, unlike a bare cancellation check.
    private let frameGate = DispatchQueue(label: "com.deviceterm.device.frame-gate")
    private var frameToken: UInt64 = 0
    private var frameTask: Task<Void, Never>?
    /// Delinquency watchdog: it **only diagnoses and logs** holds that outlive
    /// the threshold. It never force-reclaims a live lease on elapsed time (that
    /// would reintroduce the corruption the lease loop eliminates). Recovery from
    /// a genuinely stuck pool is the frame loop's job on sustained exhaustion.
    private var watchdogTask: Task<Void, Never>?
    /// App Switcher macros in flight. Mutated from the gesture task that
    /// enqueues one and read from the transfer that cancels them, so it lives
    /// under `inputGate` like the rest of this backend's input state.
    private var appSwitcherRequests: [AppSwitcherRequest] = []
    private let humanInputStream: AsyncStream<PumpItem<HumanInputWork>>
    private let humanInputContinuation: AsyncStream<PumpItem<HumanInputWork>>.Continuation
    private var humanInputPump: Task<Void, Never>?
    private let buttonStream: AsyncStream<PumpItem<ButtonPress>>
    private let buttonContinuation: AsyncStream<PumpItem<ButtonPress>>.Continuation
    private var buttonPump: Task<Void, Never>?
    private let rotationStream: AsyncStream<PumpItem<RotationRequest>>
    private let rotationContinuation: AsyncStream<PumpItem<RotationRequest>>.Continuation
    private var rotationPump: Task<Void, Never>?
    private let locationStream: AsyncStream<PumpItem<LocationRequest>>
    private let locationContinuation: AsyncStream<PumpItem<LocationRequest>>.Continuation
    private var locationPump: Task<Void, Never>?
    private let keyStream: AsyncStream<PumpItem<KeyCommand>>
    private let keyContinuation: AsyncStream<PumpItem<KeyCommand>>.Continuation
    private var keyPump: Task<Void, Never>?

    // MARK: Ownership-transfer input fence
    //
    // Serialised on `inputGate` (a documented DispatchQueue, the sanctioned
    // pattern for cross-thread state here: the enqueue witnesses run on the
    // coordinator's task, the quiesce on the coordinator actor). Each admitted
    // verb is stamped with `inputGeneration`; the pump drops any item whose
    // stamp isn't current. `quiesceInputForTransfer` bumps the generation
    // (invalidating buffered work), barriers each live pump to wait out the
    // in-flight send, then releases held state. `resumeInput` bumps again: a
    // fresh generation so a stale gesture waking after resume can never match
    // (ABA guard).
    private let inputGate = DispatchQueue(label: "com.deviceterm.device.input-gate")
    private var inputGeneration: UInt64 = 1
    /// True once the media-stream auth gate opened (first decoded frame),
    /// so the gated human-input / keyboard pumps are draining their streams.
    /// The quiesce barriers a gated pump only when this is true: an
    /// unopened pump has sent nothing and would never process a barrier.
    private var inputGateOpened = false
    /// Last touch contact still held (nil once lifted): the whole
    /// `TouchInput`, so a transfer releases it with the **same kind**
    /// (`.direct` / `.systemGesture(edge)` / `.appSwitcher(edge)`); a
    /// `.direct` lift can't release a held system-gesture contact. Plus the
    /// HID usages still pressed. Tracked as the pump actually performs.
    private var heldTouch: TouchInput?
    private var heldKeys: Set<UInt16> = []
    /// Buttons whose press landed but whose release hasn't confirmed, so a
    /// failed release doesn't strand one. A **list**, not a single value: a
    /// button whose release failed stays here, and a later press must not
    /// overwrite it (`Control` isn't `Hashable`, so a list, not a set).
    private var heldButtons: [ButtonInput.Control] = []
    // "Media-stream auth gate is open" fan-out: the input channels exist from
    // attach, but the device only *routes* touch + keyboard reports once a stream
    // holds the auth gate open, so those pumps wait for the first decoded frame
    // and input enqueued meanwhile buffers in its stream. Each gated pump gets
    // its own one-shot gate; the frame task yields to all of them on the first
    // frame.
    private let gateContinuations: [AsyncStream<Void>.Continuation]

    /// Capabilities mirror what the relay's channels actually opened. Touch and
    /// keyboard share the human-input surface; buttons and rotation depend on
    /// their optional channels. Crown and accessibility have no physical-device
    /// path.
    var capabilities: DeviceBackendCapabilities {
        DeviceBackendCapabilities(
            touch: device.support.touch,
            key: device.support.keyboard,
            text: device.support.keyboard,
            button: device.support.buttons,
            rotate: device.support.rotation,
            crown: false,
            accessibility: false,
            // Location rides `devicectl`, not the relay's channels, so
            // it does not depend on which roles opened.
            location: true
        )
    }

    init(
        deviceId: String,
        feed: any DecodedFrameFeed,
        device: any InteractionRelaying,
        location: any DeviceLocationSimulating = DeviceCtlLocation(),
        diagnostics: (@Sendable (String) -> Void)? = nil
    ) {
        self.deviceId = deviceId
        self.feed = feed
        self.device = device
        self.location = location
        self.onDiagnostic = diagnostics
        let sink = FrameMetricsSink.make(
            baseDirectory: ProcessInfo.processInfo.environment[DeviceTermEnv.frameMetrics],
            deviceId: deviceId,
            log: diagnostics
        )
        metricsSink = sink
        signposter = sink == nil
            ? .disabled
            : OSSignposter(subsystem: "com.deviceterm.daemon", category: "mirror")
        let slotCount = ProcessInfo.processInfo.environment[DeviceTermEnv.surfacePoolSlots]
            .flatMap(Int.init) ?? Self.defaultPoolSlots
        self.pool = LeasedSurfacePool(slotCount: slotCount, recordHoldAges: sink != nil)
        (humanInputStream, humanInputContinuation) = AsyncStream<PumpItem<HumanInputWork>>.makeStream()
        (buttonStream, buttonContinuation) = AsyncStream<PumpItem<ButtonPress>>.makeStream()
        (rotationStream, rotationContinuation) = AsyncStream<PumpItem<RotationRequest>>.makeStream()
        (locationStream, locationContinuation) = AsyncStream<PumpItem<LocationRequest>>.makeStream()
        (keyStream, keyContinuation) = AsyncStream<PumpItem<KeyCommand>>.makeStream()
        let (humanInputGate, humanInputGateContinuation) = AsyncStream<Void>.makeStream()
        let (keyGate, keyGateContinuation) = AsyncStream<Void>.makeStream()
        gateContinuations = [humanInputGateContinuation, keyGateContinuation]
        startHumanInputPump(gate: humanInputGate)
        startKeyPump(gate: keyGate)
        startButtonPump()
        startRotationPump()
        startLocationPump()
    }

    deinit {
        // Explicit lifetime end for the input pumps. Each pump captures `device`
        // (never `self`), so it outlives the backend until its command stream
        // ends. Finishing the streams here drains any buffered in-flight commands
        // and ends the pumps, releasing the relay. The gate streams are finished
        // too, in case no frame ever opened them. `shutdownBackend` deliberately
        // leaves the pumps running so an in-flight gesture/press isn't cut, since
        // the backend is still referenced while a gesture is being issued.
        gateContinuations.forEach { $0.finish() }
        humanInputContinuation.finish()
        buttonContinuation.finish()
        rotationContinuation.finish()
        locationContinuation.finish()
        keyContinuation.finish()
    }

    /// Map a `HardwareButton` to its control and the deviceterm-defined press
    /// duration. On a Face-ID device the side button *is* the power button, so
    /// `lock` and `side` both map to power. Apple Pay (no hardware HID path) and
    /// the watch Digital Crown press (no hardware) stay unsupported.
    static func buttonPress(for button: HardwareButton) -> ButtonPress? {
        switch button {
        case .home:
            return ButtonPress(control: .home, holdNanos: 80_000_000)

        case .lock, .side:
            return ButtonPress(control: .power, holdNanos: 350_000_000)

        case .siri:
            return ButtonPress(control: .assistant, holdNanos: 750_000_000)

        case .applePay, .digitalCrown:
            return nil
        }
    }

    /// Step the device from `current` (nil ⇒ unknown) to `target`, returning the
    /// orientation it ends at. Learns the current orientation with one step when
    /// unknown, then steps the minimal direction; bounded so a stuck device can't
    /// loop forever.
    private static func rotate(
        _ device: any InteractionRelaying,
        current: Orientation?,
        target: Orientation
    ) async throws -> Orientation? {
        // `try` (not `try?`): a thrown step is a real relay/tunnel failure and
        // must propagate so the caller reports the rotation as *not performed*.
        // Only a *successful* step that reports no absolute orientation
        // (`.acknowledged` / `.orientation(nil)`) yields `nil` here, and that
        // is the sole case the dead-reckoning fallback below fills in, never a
        // thrown failure.
        var here = current
        if here == nil {
            here = orientation(from: try await device.perform(.rotate(.left)))
            guard here != nil else { return nil }
        }
        var steps = 0
        while let now = here, now != target, steps < 4 {
            steps += 1
            guard let direction = DeviceOrientationMath.direction(from: now, to: target) else { break }
            let reported = orientation(from: try await device.perform(.rotate(direction)))
            here = reported ?? DeviceOrientationMath.step(now, direction)
        }
        return here
    }

    /// Translate a location failure into the backend vocabulary the
    /// coordinator maps to wire errors.
    ///
    /// Without this the raw `DeviceCtlLocationError` escapes untranslated.
    /// `PaneCoordinator.setLocation` does have a general catch that turns
    /// anything unrecognized into `bridgeFailed`, so nothing leaks as a
    /// bare `serverError`. But a rejected scenario name would land there
    /// too, reported as a bridge fault rather than the `invalidParams`
    /// the simulator backend returns for the identical mistake. That
    /// parity is a documented contract, so the classification belongs
    /// here, where the tool's own vocabulary is still legible.
    ///
    /// A `DeviceBackendError` (the pump's own transfer fence, say) passes
    /// through unchanged.
    private static func locationFailure(_ error: any Error) -> any Error {
        switch error {
        case let backendError as DeviceBackendError:
            return backendError

        case let DeviceCtlLocationError.unknownScenario(name):
            return DeviceBackendError.unknownLocationScenario(name: name)

        // A command that ran and failed, not an acquisition failure, so
        // it must not borrow `locationUnavailable`, whose wire mapping
        // hardcodes the `location.acquire` label.
        case let DeviceCtlLocationError.commandFailed(_, message):
            return DeviceBackendError.locationCommandFailed(
                message: message.isEmpty ? "devicectl reported a failure" : message
            )

        // The tool ran and exited cleanly, but its payload wasn't what
        // this version knows how to read. Kept distinct from an
        // unreachable device so a caller can degrade and still report it.
        // Otherwise schema drift shows up only as every device having no
        // trips.
        case DeviceCtlLocationError.malformedOutput:
            return DeviceBackendError.locationOutputMalformed(
                message: "devicectl location output didn't match the expected schema"
            )

        case DeviceCtlLocationError.missingOutput:
            return DeviceBackendError.locationOutputMalformed(
                message: "devicectl exited cleanly but wrote no --json-output payload"
            )

        // Host-side, and `devicectl` never ran. Still a command failure
        // rather than an acquisition one: the caller asked to play a
        // route and it didn't play, which is what the wire error should
        // say. `location.acquire` would blame a step this got past.
        case let DeviceCtlLocationError.routeFileUnwritable(message):
            return DeviceBackendError.locationCommandFailed(
                message: "couldn't write the route file for devicectl: \(message)"
            )

        default:
            return DeviceBackendError.locationUnavailable(message: "\(error)")
        }
    }

    /// The absolute orientation a rotate outcome reports, if any.
    private static func orientation(from outcome: InteractionOutcome?) -> Orientation? {
        guard case let .orientation(name)? = outcome, let name else { return nil }
        return Orientation(rawValue: name)
    }

    /// The serial human-input pump: waits for the media-stream auth gate (the
    /// first frame), then drains touch, live edge-gesture, and App Switcher
    /// intents in order through the relay. Touch and the App Switcher share this
    /// pump, so a tap and a swipe never interleave. Input enqueued before the
    /// gate opens buffers and drains once it does. Captures only `device` + the
    /// stream (never `self`) so the backend can dealloc.
    private func startHumanInputPump(gate: AsyncStream<Void>) {
        let device = self.device
        let stream = humanInputStream
        humanInputPump = Task { [weak self] in
            var gateIterator = gate.makeAsyncIterator()
            guard await gateIterator.next() != nil else { return }
            self?.markInputGateOpened()
            for await item in stream {
                switch item {
                case let .perform(generation, work):
                    let input = work.input
                    guard self?.isInputGenerationCurrent(generation) == true else {
                        work.completion?()
                        continue
                    }
                    defer { work.completion?() }
                    work.onStart?()
                    // Record held state only if the send actually landed:
                    // a failed lift must not clear a genuinely-held contact
                    // (which quiesce would then never release).
                    if (try? await device.perform(.touch(input))) != nil {
                        self?.noteTouchPerformed(input)
                    } else {
                        self?.noteTouchSendFailed(input)
                    }

                case let .barrier(signal):
                    signal()
                }
            }
        }
    }

    /// The serial keyboard pump: waits for the auth gate (like human input), then
    /// drains key transitions through the relay. The relay owns the virtual
    /// keyboard's lifecycle (lazy registration, the delta-less pressed set, and
    /// rebuild-on-failure); this pump just emits down/up intents. Its own channel
    /// keeps a failed keyboard from disturbing touch or the mirror.
    private func startKeyPump(gate: AsyncStream<Void>) {
        let device = self.device
        let stream = keyStream
        keyPump = Task { [weak self] in
            var gateIterator = gate.makeAsyncIterator()
            guard await gateIterator.next() != nil else { return }
            self?.markInputGateOpened()
            for await item in stream {
                switch item {
                case let .perform(generation, command):
                    guard self?.isInputGenerationCurrent(generation) == true else { continue }
                    let sent: Bool
                    switch command {
                    case let .down(usage):
                        sent = (try? await device.perform(.keyDown(KeyboardInput(usage: usage)))) != nil

                    case let .up(usage):
                        sent = (try? await device.perform(.keyUp(KeyboardInput(usage: usage)))) != nil
                    }
                    // Record only on a successful send: a failed key-up must
                    // not clear a genuinely-held key.
                    if sent { self?.noteKeyPerformed(command) }

                case let .barrier(signal):
                    signal()
                }
            }
        }
    }

    /// The serial button pump: drains presses and sends each as press → hold →
    /// release so presses never interleave. No gate: buttons route without a
    /// media stream. The daemon times the hold here; the relay just sends phases.
    /// Captures only `device` + the stream.
    private func startButtonPump() {
        let device = self.device
        let stream = buttonStream
        buttonPump = Task { [weak self] in
            for await item in stream {
                switch item {
                case let .perform(generation, press):
                    guard self?.isInputGenerationCurrent(generation) == true else { continue }
                    // Track the button as held between a successful press and
                    // its successful release, so if the *release* send fails
                    // the transfer quiesce still lifts it (a swallowed failed
                    // release would otherwise strand the button down).
                    let pressed = (try? await device.perform(
                        .button(ButtonInput(control: press.control, phase: .press))
                    )) != nil
                    if pressed { self?.noteButtonHeld(press.control) }
                    try? await Task.sleep(nanoseconds: press.holdNanos)
                    let released = (try? await device.perform(
                        .button(ButtonInput(control: press.control, phase: .release))
                    )) != nil
                    if pressed, released { self?.noteButtonReleased(press.control) }

                case let .barrier(signal):
                    signal()
                }
            }
        }
    }

    /// Serialize location mutations and fence them against an ownership
    /// transfer. Both matter because each command suspends on a
    /// `devicectl` subprocess: without the pump two in-flight commands
    /// could complete out of order, and a command admitted before a
    /// transfer could land after ownership flipped.
    private func startLocationPump() {
        let location = self.location
        let deviceId = self.deviceId
        let stream = locationStream
        locationPump = Task { [weak self] in
            for await item in stream {
                switch item {
                case let .perform(generation, request):
                    // Fenced by a transfer that bumped the generation.
                    // Report it to the caller (whose ownership is gone)
                    // rather than mutating the new owner's device.
                    guard self?.isInputGenerationCurrent(generation) == true else {
                        request.completion(.failure(DeviceBackendError.notActive))
                        continue
                    }
                    do {
                        switch request.command {
                        case let .coordinate(latitude, longitude):
                            try await location.setCoordinate(
                                deviceId: deviceId,
                                latitude: latitude,
                                longitude: longitude
                            )

                        case let .scenario(name):
                            try await location.setScenario(deviceId: deviceId, name: name)

                        case let .route(spec):
                            try await location.startRoute(deviceId: deviceId, spec: spec)

                        case .clear:
                            try await location.clear(deviceId: deviceId)
                        }
                        request.completion(.success(()))
                    } catch {
                        request.completion(.failure(Self.locationFailure(error)))
                    }

                case let .barrier(signal):
                    signal()
                }
            }
        }
    }

    /// The serial rotation pump: drains absolute-orientation targets and steps
    /// the device to each. The device rotates only relative 90° steps, so the
    /// pump tracks the current orientation (learned once, then updated from each
    /// reply) and steps the minimal direction. Serial, so overlapping rotates
    /// don't fight. Captures only `device` + the stream.
    private func startRotationPump() {
        let device = self.device
        let stream = rotationStream
        rotationPump = Task { [weak self] in
            var current: Orientation?
            for await item in stream {
                switch item {
                case let .perform(generation, request):
                    // Fenced by a transfer that bumped the generation: drop it
                    // and report *not performed* so the coordinator suppresses
                    // the broadcast.
                    guard self?.isInputGenerationCurrent(generation) == true else {
                        request.completion(false)
                        continue
                    }
                    do {
                        let reached = try await Self.rotate(device, current: current, target: request.orientation)
                        current = reached
                        // Performed only if the device actually settled on the
                        // requested orientation: a rotation that ran but never
                        // reached the target reports `false`.
                        request.completion(reached == request.orientation)
                    } catch {
                        // A relay/tunnel failure on a step: the rotation did not
                        // complete, so report not-performed and forget the
                        // tracked orientation: the device's true orientation is
                        // now unknown and the next rotation re-establishes it.
                        current = nil
                        request.completion(false)
                    }

                case let .barrier(signal):
                    signal()
                }
            }
        }
    }

    // MARK: Frames

    func startFrames(
        onFrame: @escaping @Sendable (PublishedSurface) -> Void,
        onFatal: @escaping @Sendable (String) -> Void,
        onDisconnect: @escaping @Sendable () -> Void
    ) throws {
        let pool = self.pool
        let gates = gateContinuations
        let log = self.onDiagnostic
        let recoveryThreshold = Self.exhaustionRecoveryThreshold
        let metricsSink = self.metricsSink
        let signposter = self.signposter
        // Install a fresh run token; teardown bumps it to fence late callbacks.
        // `publish`/`fail` invoke the caller's callback only while the token is
        // still current, checked and invoked together under `frameGate`, so
        // teardown and a callback are mutually ordered with no race window.
        let gate = frameGate
        let token = gate.sync {
            frameToken += 1
            return frameToken
        }
        // Weak self: the feed stores `fail` as its `onFatal`, so a strong capture
        // would form a `backend → feed → fail → backend` retain cycle that keeps
        // the backend alive after its pane closes. Its `deinit` (which finishes
        // the input streams and releases the relay/channels) would never run.
        let publish: @Sendable (PublishedSurface) -> Void = { [weak self] published in
            guard let self else { return }
            gate.sync { if token == self.frameToken { onFrame(published) } }
        }
        let fail: @Sendable (String) -> Void = { [weak self] reason in
            guard let self else { return }
            gate.sync { if token == self.frameToken { onFatal(reason) } }
        }
        // The run token separates a stream that ended on its own from one this
        // backend stopped: `stopFrames` / `shutdownBackend` bump the token
        // before cancelling the frame task, so a teardown-driven end of the
        // loop finds the token stale and reports nothing.
        let disconnected: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            gate.sync { if token == self.frameToken { onDisconnect() } }
        }
        // A terminal pipeline failure fails the pane the same way pool exhaustion
        // does: the feed forwards it (fenced) straight into this channel.
        let frames = feed.frames(onFatal: fail)
        // Local, like every other capture below: reaching `self.feed` from
        // inside the frame task would retain the backend for the life of the
        // stream and keep `deinit` from ever running.
        let feed = self.feed
        // Off-by-default tracing: when on, stamp the frame's pool generation into
        // the copied slot so the GUI can compare the generation it intended to
        // render against what it scans back, and carry it on the published frame.
        let tracing = SurfaceTraceSink.daemonProducer != nil
        frameTask = Task {
            var openedGate = false
            // Consecutive exhaustion drops. Sustained exhaustion (the GUI isn't
            // acking, e.g. after a reconnect stranded holds) triggers one
            // controlled pool recovery; a second bout fails the pane.
            var consecutiveDrops = 0
            // The real content rect within the decoded (padded) surface, and the
            // surface dims it was measured for. Locked once a frame can be sized
            // confidently; reset when the surface dims change (e.g. rotation).
            var contentSize: (width: Int, height: Int)?
            var contentForDims: (Int, Int)?
            var frameIndex = 0
            // Nil unless metrics are armed, which is what keeps the clock reads
            // below out of an ordinary run. The first frame opens the window
            // rather than the task doing it: a stream that takes seconds to
            // produce one would otherwise close an empty window first and emit
            // a row carrying no geometry and no outcome.
            var metrics: DeviceFrameMetrics?
            for await frame in frames {
                // Close the window *before* counting this frame, so no window
                // holds a frame's arrival without its outcome. Counting first
                // would put the boundary frame's `noteConsumed` in one row and
                // its copy and publish in the next, and every row would
                // contradict `framesConsumed == framesPublished + drops`.
                if let metricsSink {
                    let now = DispatchTime.now().uptimeNanoseconds
                    if metrics == nil {
                        metrics = DeviceFrameMetrics(startNanoseconds: now)
                    } else if let elapsed = metrics?.elapsedNanoseconds(now: now),
                        elapsed >= Self.metricsWindowNanoseconds {
                        let leaseHold = await pool.drainHoldAges()
                        if let summary = metrics?.summarize(now: now, leaseHold: leaseHold) {
                            metricsSink.record(summary)
                        }
                        metrics?.startWindow(at: now)
                    }
                }
                metrics?.noteConsumed()
                if !openedGate {
                    // First frame ⇒ the stream is live and the HID auth gate is
                    // open: release every gated pump (human input + keyboard).
                    openedGate = true
                    gates.forEach { $0.yield(); $0.finish() }
                }
                guard let ioSurface = CVPixelBufferGetIOSurface(frame.pixelBuffer)?.takeUnretainedValue() else {
                    metrics?.noteDroppedNoSurface()
                    continue
                }
                let dims = (IOSurfaceGetWidth(ioSurface), IOSurfaceGetHeight(ioSurface))
                if contentForDims?.0 != dims.0 || contentForDims?.1 != dims.1 {
                    contentSize = nil
                    contentForDims = dims
                    frameIndex = 0
                }
                // Probe for the content rect until one frame locks it. Cheap and
                // throttled so a dark frame that can't be sized yet retries slowly
                // instead of rescanning constantly.
                if contentSize == nil, frameIndex.isMultiple(of: Self.paddingDetectionInterval) {
                    contentSize = DevicePadding.contentSize(of: ioSurface)
                }
                frameIndex += 1
                let contentDims = SurfaceCopy.contentDimensions(source: ioSurface, contentSize: contentSize)
                // Before the acquire guard, so a drop reports the geometry of
                // the frame that dropped. Recording it after would leave an
                // exhaustion row describing the previous resolution, which is
                // exactly the frame a rotation fails to acquire for.
                metrics?.noteGeometry(
                    sourceWidth: dims.0,
                    sourceHeight: dims.1,
                    contentWidth: contentDims.width,
                    contentHeight: contentDims.height,
                    pixelFormat: IOSurfaceGetPixelFormat(ioSurface)
                )
                // Exhaustion (no free slot) drops the frame: never blocks decode
                // or backlogs. Sustained exhaustion drives one controlled
                // recovery, then fails the pane.
                guard var published = await pool.acquire(width: contentDims.width, height: contentDims.height)
                else {
                    metrics?.noteDroppedExhaustion()
                    consecutiveDrops += 1
                    if consecutiveDrops >= recoveryThreshold {
                        consecutiveDrops = 0
                        switch await pool.recoverFromExhaustion() {
                        case .recovered:
                            log?("surface pool exhausted; retired the active "
                                + "epoch; the next frame allocates a fresh pool")

                        case .exhausted:
                            // Fenced: dropped if teardown already invalidated the
                            // run token, so no fatal escapes after stop.
                            fail("surface pool exhausted and could not "
                                + "recover; the mirror can't reclaim held slots")
                            return
                        }
                    }
                    continue
                }
                consecutiveDrops = 0
                // The decoder owns `frame.pixelBuffer`; copy it into the pool slot
                // before publishing so the published surface is never the
                // decoder's (which VideoToolbox may recycle). `frame` stays
                // retained across the copy.
                let copyStart = metricsSink == nil ? 0 : DispatchTime.now().uptimeNanoseconds
                let copyInterval = signposter.beginInterval("copy")
                // The copy reports what it moved rather than the metrics
                // recomputing it: an uncropped copy spans the whole row stride,
                // alignment padding included, so deriving the figure from the
                // content rect would undercount the bandwidth.
                let bytesCopied = published.surface.withRef { destination in
                    SurfaceCopy.copy(from: ioSurface, to: destination, contentSize: contentSize)
                }
                signposter.endInterval("copy", copyInterval)
                if metricsSink != nil {
                    metrics?.noteCopy(
                        nanoseconds: DispatchTime.now().uptimeNanoseconds &- copyStart,
                        bytes: bytesCopied
                    )
                }
                if tracing, let generation = published.lease?.generation {
                    published.surface.withRef { SurfacePixelStamp.stamp(generation, into: $0) }
                    published.trace = SurfaceTraceStamp(
                        traceId: generation,
                        producedAtNanoseconds: DispatchTime.now().uptimeNanoseconds
                    )
                }
                // `publish` re-checks the run token under `frameGate` and fires
                // `onFrame` only if teardown hasn't invalidated this run, so a
                // publish can't escape after `stopFrames`/`shutdownBackend`, even
                // though `acquire` above was a suspension point.
                publish(published)
                metrics?.notePublished()
            }
            // Falling out of the loop says the stream ended, not why. Every
            // ending arrives here the same way, including the two that must
            // not re-mirror: a feed that gave up having never worked, and a
            // teardown this backend asked for.
            //
            // So ask the feed, rather than inferring. Waiting to hear from
            // `fail` instead is a race this loop can lose, because a feed
            // finishes its stream *before* it calls `onFatal`; the verdict is
            // settled before the finish this loop just observed. The run token still fences the answer, so a teardown
            // reports nothing even if the feed classified it otherwise.
            //
            // Pool exhaustion never reaches here: it `return`s above, having
            // already reported through `fail`.
            if feed.termination == .disconnected { disconnected() }
        }
        startWatchdog()
    }

    /// Periodically observe delinquent holds: diagnosis and telemetry only. The
    /// pool counts them; here we surface a rate-limited log so a stuck consumer
    /// is visible without ever reclaiming its slot.
    private func startWatchdog() {
        guard watchdogTask == nil else { return }
        let pool = self.pool
        let log = self.onDiagnostic
        watchdogTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.watchdogIntervalNanoseconds)
                if Task.isCancelled { return }
                let delinquents = await pool.diagnoseDelinquent()
                guard !delinquents.isEmpty, let log else { continue }
                for hold in delinquents {
                    let ageMs = hold.ageNanoseconds / 1_000_000
                    log(
                        "surface-lease: delinquent hold epoch=\(hold.epoch) "
                        + "generation=\(hold.generation) age=\(ageMs)ms; "
                        + "still dropping frames, not reclaiming"
                    )
                }
            }
        }
    }

    // MARK: - Lease forwarders (to the pool)

    func registerLeaseToken(_ token: UUID, connectionId: UInt64) async {
        await pool.registerToken(token, connectionId: connectionId)
    }

    func unregisterLeaseTokenIfUnused(_ token: UUID) async -> Bool {
        await pool.unregisterTokenIfUnused(token)
    }

    func releaseWatermark(token: UUID, epoch: UInt64, lowestHeld: UInt64, connectionId: UInt64) async {
        await pool.applyWatermark(
            token: token,
            epoch: epoch,
            lowestHeld: lowestHeld,
            connectionId: connectionId
        )
    }

    func drain(token: UUID) async {
        await pool.beginDrain(token)
    }

    func orphan(token: UUID) async {
        await pool.orphan(token)
    }

    func stopFrames() {
        invalidateFrameRun()
        frameTask?.cancel()
        frameTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        feed.stop()
    }

    /// Invalidate the current frame run so any in-flight or subsequently-scheduled
    /// `publish`/`fail` is dropped. Serialised with the callbacks on `frameGate`.
    private func invalidateFrameRun() {
        frameGate.sync { frameToken += 1 }
    }

    /// Device displays report their pixel size through the surface stream, not up
    /// front; the GUI sizes from the surface it receives.
    func pixelDimensions() -> (Int?, Int?) { (nil, nil) }

    // MARK: Display orientation
    //
    // Not observed on this backend, so the pane keeps the orientation from
    // its last DeviceTerm command and a device rotated by hand leaves it
    // showing the previous one.
    //
    // The nearest reachable source is the device-control orientation
    // channel this backend already speaks: `HIDReports.orientationRequest`
    // sends a `rotate` and the relay parses `currentDeviceOrientation` out
    // of the reply (`InteractionRelay.sendRotation`). That reports attitude
    // rather than the framebuffer, and a read-only form of the request has
    // not been confirmed against a device, so neither is recorded here as
    // fact.

    func startDisplayOrientation(
        onChange: @escaping @Sendable (Orientation) -> Void
    ) -> Bool { false }

    func stopDisplayOrientation() {}

    func currentDisplayOrientation() -> Orientation? { nil }

    // MARK: Touch (normalized 0…1; scaled to device coordinates by the relay)

    func tapDown(at point: CGPoint, generation: UInt64) throws {
        enqueueTouch(TouchInput(point: devicePoint(point), phase: .contact, kind: .direct), generation: generation)
    }

    func tapUp(at point: CGPoint, generation: UInt64) throws {
        enqueueTouch(TouchInput(point: devicePoint(point), phase: .lift, kind: .direct), generation: generation)
    }

    // Live edge touch: a bottom-edge mouse drag follows the cursor into the App
    // Switcher, the interactive analogue of the scripted `openAppSwitcher`. A
    // *plain* synthetic digitizer touch reaches the foreground app, not
    // SpringBoard's recognizer, so each contact is sent as an enriched
    // system-gesture report (the relay adds the trailer + nanosecond timestamp).
    // Coordinates arrive already rotated into the device-native frame; `edge`
    // selects the trailer's orientation. Enqueued onto the gated human-input
    // pump, like taps.
    func edgeTouchDown(at point: CGPoint, edge: Int, generation: UInt64) throws {
        enqueueTouch(
            TouchInput(point: devicePoint(point), phase: .contact, kind: .systemGesture(gestureEdge(from: edge))),
            generation: generation
        )
    }

    func edgeTouchMove(at point: CGPoint, edge: Int, generation: UInt64) throws {
        enqueueTouch(
            TouchInput(point: devicePoint(point), phase: .contact, kind: .systemGesture(gestureEdge(from: edge))),
            generation: generation
        )
    }

    func edgeTouchUp(at point: CGPoint, edge: Int, generation: UInt64) throws {
        enqueueTouch(
            TouchInput(point: devicePoint(point), phase: .lift, kind: .systemGesture(gestureEdge(from: edge))),
            generation: generation
        )
    }

    /// Open the App Switcher via a scripted system-gesture swipe on the device's
    /// touchscreen (enqueued onto the gated human-input pump, like touch). `edge`
    /// is the `IndigoHIDEdge` value of the home-indicator's current display edge;
    /// the relay drives the swipe geometry. Always wired (the human-input
    /// surface is always present) so the coordinator's double-press fallback is
    /// reserved for backends without this path.
    /// Returns once the relay's trajectory has finished, so the caller's lease
    /// covers the whole macro. Enqueueing and returning would release the lane
    /// while the device was still being driven, which is exactly the overlap
    /// the lane exists to prevent.
    func openAppSwitcher(edge: Int, generation: UInt64) async throws {
        let cancellation = InteractionCancellation()
        let request = AppSwitcherRequest(cancellation: cancellation)
        inputGate.sync { appSwitcherRequests.append(request) }
        defer { inputGate.sync { appSwitcherRequests.removeAll { $0 === request } } }
        // The human-input pump only consumes work once the media stream's auth
        // gate opens on the first frame. If no frame ever arrives the enqueued
        // macro sits there, and an unbounded wait would hold the pane's lane
        // and, through it, a deferred close's cleanup. Give up after a bound
        // instead; the cancellation makes the buffered macro a no-op if it
        // drains later.
        //
        // Bounds admission only. Once the pump starts the macro this is
        // cancelled, because a trajectory that runs long still has to finish
        // and lift rather than be abandoned partway.
        let admissionDeadline = Task { [weak request] in
            try? await Task.sleep(nanoseconds: Self.appSwitcherAdmissionTimeoutNanos)
            guard !Task.isCancelled else { return }
            request?.cancellation.cancel()
            request?.finish()
        }
        defer { admissionDeadline.cancel() }
        let input = TouchInput(
            point: DevicePoint(x: 0, y: 0),
            phase: .contact,
            kind: .appSwitcher(gestureEdge(from: edge)),
            cancellation: cancellation
        )
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            request.install(continuation)
            humanInputContinuation.yield(
                .perform(
                    generation: generation,
                    HumanInputWork(
                        input,
                        onStart: { admissionDeadline.cancel() },
                        completion: { request.finish() }
                    )
                )
            )
        }
    }

    /// Stop an App Switcher macro that is queued or mid-trajectory.
    ///
    /// Cancels the request rather than the pump: the pump is one task draining
    /// the stream for the backend's whole life, so cancelling it would disable
    /// every later input on this pane.
    func cancelAppSwitcherRequests() {
        for request in inputGate.sync(execute: { appSwitcherRequests }) {
            request.cancellation.cancel()
        }
    }

    /// Map the `IndigoHIDEdge` value the GUI tags a system-gesture swipe with to
    /// the device-native originating edge. iOS keeps the home indicator on the
    /// displayed bottom: the native bottom in portrait, a native side in
    /// landscape; anything unrecognized (e.g. the upside-down fallback, which has
    /// no home gesture) degrades to the bottom edge.
    private func gestureEdge(from indigoEdge: Int) -> GestureEdge {
        if indigoEdge == AppSwitcherGesture.edge(for: .landscapeLeft) { return .left }
        if indigoEdge == AppSwitcherGesture.edge(for: .landscapeRight) { return .right }
        return .bottom
    }

    func twoFingerDown(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws {
        throw RealDeviceBackendError.unsupported(verb: "two-finger input")
    }

    func twoFingerUp(f1 finger1: CGPoint, f2 finger2: CGPoint, generation: UInt64) throws {
        throw RealDeviceBackendError.unsupported(verb: "two-finger input")
    }

    private func devicePoint(_ point: CGPoint) -> DevicePoint {
        DevicePoint(x: point.x, y: point.y)
    }

    // MARK: Keyboard / buttons / rotation (capability-gated) + unsupported verbs

    func keyDown(hidUsage: UInt32, generation: UInt64) throws {
        let usage = UInt16(truncatingIfNeeded: hidUsage)
        keyContinuation.yield(.perform(generation: generation, .down(usage)))
    }

    func keyUp(hidUsage: UInt32, generation: UInt64) throws {
        let usage = UInt16(truncatingIfNeeded: hidUsage)
        keyContinuation.yield(.perform(generation: generation, .up(usage)))
    }

    func pressHardwareButton(_ button: HardwareButton, generation: UInt64) throws {
        guard device.support.buttons, let press = Self.buttonPress(for: button) else {
            throw RealDeviceBackendError.unsupported(verb: "the \(button.rawValue) button")
        }
        buttonContinuation.yield(.perform(generation: generation, press))
    }

    func rotate(to orientation: Orientation, generation: UInt64) async throws -> Bool {
        guard device.support.rotation else {
            throw RealDeviceBackendError.unsupported(verb: "rotation")
        }
        // Enqueue the rotation carrying a completion the pump resumes with the
        // specific command's outcome (performed & reached target, or dropped),
        // and await it, so the coordinator broadcasts only for a rotation the
        // device truly made. A finished stream (torn-down pump) reports `false`.
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let request = RotationRequest(orientation: orientation) { continuation.resume(returning: $0) }
            let outcome = rotationContinuation.yield(.perform(generation: generation, request))
            if case .terminated = outcome { continuation.resume(returning: false) }
        }
    }

    /// Enqueue a touch, stamped with the operation's captured `generation`
    /// (not the current one) so a transfer that bumps the generation while
    /// the paced gesture is still looping drops every one of its later
    /// sends before it reaches the new owner.
    private func enqueueTouch(_ input: TouchInput, generation: UInt64) {
        humanInputContinuation.yield(.perform(generation: generation, HumanInputWork(input)))
    }

    func rotateCrown(delta: Double, generation: UInt64) throws {
        throw RealDeviceBackendError.unsupported(verb: "crown")
    }

    // MARK: Location simulation

    // Mutations ride the location pump so they serialize against each
    // other and participate in the ownership-transfer fence; see
    // `startLocationPump`. The read goes direct: it mutates nothing.
    //
    // An unknown scenario name is forwarded rather than pre-checked.
    // `devicectl` is a separate process that reports its own failure
    // (exit 1, CoreDeviceError 20001), so a pre-check would cost a second
    // subprocess round trip per set; the simulator backend must pre-check
    // because CoreSimulator's setter accepts unknown names silently
    // instead. Both paths converge on
    // `DeviceBackendError.unknownLocationScenario` via `locationFailure`,
    // so the two backends answer a typo identically.

    func setSimulatedLocation(latitude: Double, longitude: Double, generation: UInt64) async throws {
        try await enqueueLocation(
            .coordinate(latitude: latitude, longitude: longitude),
            generation: generation
        )
    }

    func setSimulatedLocationScenario(_ name: String, generation: UInt64) async throws {
        try await enqueueLocation(.scenario(name), generation: generation)
    }

    func startSimulatedLocationRoute(_ spec: RouteSpec, generation: UInt64) async throws {
        try await enqueueLocation(.route(spec), generation: generation)
    }

    func clearSimulatedLocation(generation: UInt64) async throws {
        try await enqueueLocation(.clear, generation: generation)
    }

    /// Bypasses the pump, since it mutates nothing, but still translates
    /// its failures so a caller that surfaces them sees backend
    /// vocabulary rather than a raw `devicectl` error.
    func availableLocationScenarios() async throws -> [String] {
        do {
            return try await location.availableScenarios(deviceId: deviceId)
        } catch {
            throw Self.locationFailure(error)
        }
    }

    /// Enqueue a mutation and await *its* outcome. A finished stream (the
    /// pump torn down with the backend) reports `.notActive`, matching
    /// every other verb's post-teardown answer.
    private func enqueueLocation(_ command: LocationCommand, generation: UInt64) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let request = LocationRequest(command: command) { continuation.resume(with: $0) }
            let outcome = locationContinuation.yield(.perform(generation: generation, request))
            if case .terminated = outcome {
                continuation.resume(throwing: DeviceBackendError.notActive)
            }
        }
    }

    func accessibilityFrontmostTree() throws -> [String: Any] {
        throw DeviceBackendError.accessibilityUnavailable(message: "no accessibility service over the device tunnel")
    }

    func accessibilityElement(at pixelPoint: CGPoint) throws -> [String: Any] {
        throw DeviceBackendError.accessibilityUnavailable(message: "no accessibility service over the device tunnel")
    }

    // MARK: - Ownership-transfer input fence

    func currentInputGeneration() -> UInt64 { inputGate.sync { inputGeneration } }

    func isInputGenerationCurrent(_ generation: UInt64) -> Bool {
        inputGate.sync { generation == inputGeneration }
    }

    private func markInputGateOpened() { inputGate.sync { inputGateOpened = true } }

    /// Track what actually reached the device so a transfer releases
    /// exactly what's held. Called by the pump *after* a successful send.
    private func noteTouchPerformed(_ input: TouchInput) {
        // `.appSwitcher` is a self-contained trajectory that ends in its own
        // lift (the relay ignores its phase and runs the whole gesture) so
        // it is never "held". Tracking it would make quiesce submit an
        // `.appSwitcher` "lift" that re-runs the entire App Switcher on the
        // new owner.
        if case .appSwitcher = input.kind { return }
        inputGate.sync {
            switch input.phase {
            case .contact:
                heldTouch = input

            case .lift:
                heldTouch = nil
            }
        }
    }

    /// A touch send **failed**. For an `.appSwitcher` (a self-contained
    /// macro whose contact/lift the relay drives internally) a failure
    /// (both the final lift and its retry) means the contact may be down with
    /// no confirmed lift, and it is never otherwise tracked. Record a
    /// recoverable held contact on the **same gesture report path** (a
    /// `.systemGesture` release, not a plain `.direct` one, which a real
    /// device may not accept for a gesture-initiated contact) so quiesce
    /// lifts it and, until that lift confirms, blocks the transfer. For
    /// `.direct`/`.systemGesture`, a failed *contact* placed nothing and a
    /// failed *lift* leaves the prior contact tracked, so no action here.
    private func noteTouchSendFailed(_ input: TouchInput) {
        guard case let .appSwitcher(edge) = input.kind else { return }
        inputGate.sync {
            heldTouch = TouchInput(point: input.point, phase: .contact, kind: .systemGesture(edge))
        }
    }

    private func noteKeyPerformed(_ command: KeyCommand) {
        inputGate.sync {
            switch command {
            case let .down(usage):
                heldKeys.insert(usage)

            case let .up(usage):
                heldKeys.remove(usage)
            }
        }
    }

    private func noteButtonHeld(_ control: ButtonInput.Control) {
        // Hardware-button state is singular per control: append only if
        // absent, so a re-press of a button whose release failed doesn't
        // create a duplicate (a phantom hold).
        inputGate.sync { if !heldButtons.contains(control) { heldButtons.append(control) } }
    }

    private func noteButtonReleased(_ control: ButtonInput.Control) {
        inputGate.sync { heldButtons.removeAll { $0 == control } }
    }

    /// Enqueue a fence barrier on `continuation` and await it. When the
    /// pump reaches the barrier, every prior item has been processed
    /// (performed or dropped as stale) and no perform is in flight: the
    /// no-further-send fence for that pump. A finished stream (torn-down
    /// pump) resolves immediately.
    private func barrier<Value: Sendable>(_ continuation: AsyncStream<PumpItem<Value>>.Continuation) async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let outcome = continuation.yield(.barrier { waiter.resume() })
            if case .terminated = outcome { waiter.resume() }
        }
    }

    /// Free a contact left down by a gesture that failed partway. See the
    /// `DeviceBackend` requirement: no generation bump, because nothing is
    /// being transferred.
    func releaseHeldContact() async -> Bool {
        let contact: TouchInput? = inputGate.sync { heldTouch }
        guard let contact else { return true }
        // Released with the held contact's own kind, so a system-gesture
        // contact gets its matching lift rather than a plain one.
        let lift = TouchInput(point: contact.point, phase: .lift, kind: contact.kind)
        guard (try? await device.perform(.touch(lift))) != nil else {
            // A failed relay send is not proof the tunnel is down, and not
            // proof the contact lifted. Report it as still held.
            return false
        }
        inputGate.sync { if heldTouch == contact { heldTouch = nil } }
        return true
    }

    func quiesceInputForTransfer() async -> Bool {
        // (1) Invalidate the current generation. Buffered stale items are
        // now dropped by the pumps as they dequeue them; a new verb (were
        // one admitted) would carry the new generation.
        inputGate.sync { inputGeneration &+= 1 }
        // An App Switcher macro already inside the relay won't see the new
        // generation: the pump handed it over and it plays its own trajectory
        // from there. Signal it directly, so the barrier below isn't waiting
        // out a gesture that has no reason to keep going. It still lifts.
        cancelAppSwitcherRequests()
        // Tracks whether every held-input release actually landed. A failed
        // release means we can't guarantee the device is input-clean, so the
        // coordinator must NOT flip ownership (a failed relay send is not
        // proof the tunnel is down; it can be transient).
        var allReleased = true
        // (2) Barrier each live pump to wait out any in-flight send and
        // drain the now-stale buffer. A gated pump that never opened has
        // sent nothing and would never process a barrier; skip it.
        let opened = inputGate.sync { inputGateOpened }
        if opened {
            await barrier(humanInputContinuation)
            await barrier(keyContinuation)
        }
        await barrier(buttonContinuation)
        await barrier(rotationContinuation)
        await barrier(locationContinuation)
        // (3) Terminal step: release state still held on the prior owner's
        // behalf so the new owner doesn't inherit a finger or key down.
        // The pumps are now idle, so emitting directly through the relay is
        // ordered after the fenced sends by its per-channel FIFO.
        // Snapshot without clearing: each held item is cleared only once
        // its release *lands*, so a failed release isn't silently lost: it
        // stays held for a later quiesce (or a recovered channel) to retry.
        // A still-held item makes this return `false`, and the coordinator
        // then **aborts the transfer** (throws `inputNotQuiesced`) rather
        // than flipping ownership onto a device that may still hold input.
        let snapshot: HeldSnapshot = inputGate.sync {
            HeldSnapshot(touch: heldTouch, keys: heldKeys, buttons: heldButtons)
        }
        if let contact = snapshot.touch {
            // Release with the held contact's own kind: a `.systemGesture`
            // contact needs its matching lift, not a `.direct` one.
            let lift = TouchInput(point: contact.point, phase: .lift, kind: contact.kind)
            if (try? await device.perform(.touch(lift))) != nil {
                inputGate.sync { if heldTouch == contact { heldTouch = nil } }
            } else {
                allReleased = false
            }
        }
        for usage in snapshot.keys {
            guard (try? await device.perform(.keyUp(KeyboardInput(usage: usage)))) != nil else {
                allReleased = false
                continue
            }
            inputGate.sync { _ = heldKeys.remove(usage) }
        }
        for control in snapshot.buttons {
            let release = ButtonInput(control: control, phase: .release)
            guard (try? await device.perform(.button(release))) != nil else {
                allReleased = false
                continue
            }
            inputGate.sync { heldButtons.removeAll { $0 == control } }
        }
        return allReleased
    }

    func resumeInput() {
        // Fresh generation (ABA guard): a stale gesture that captured the
        // pre-quiesce generation can't match this one either.
        inputGate.sync { inputGeneration &+= 1 }
    }

    // MARK: Lifecycle

    func shutdownBackend() {
        // Stop the frame stream (the heavy, kernel-coupled resource). Per the
        // `DeviceBackend` contract, the input pumps and their streams are
        // deliberately left running so an in-flight gesture/press that captured
        // this backend completes; they release when the backend deallocs (the
        // continuation deinits end the pumps, which release the relay).
        invalidateFrameRun()
        frameTask?.cancel()
        frameTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        feed.stop()
    }
}
// swiftlint:enable unneeded_throws_rethrows
