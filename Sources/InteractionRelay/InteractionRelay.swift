// SPDX-License-Identifier: GPL-3.0-or-later

import ChannelBootstrap

/// Drives a physical device's input surfaces from typed intents, keeping the
/// device's wire vocabulary (HID reports, button events, orientation requests)
/// entirely private.
///
/// Ordering is the load-bearing property. Touch and the App Switcher ride the
/// same human-input channel, so they run on one FIFO pump and stay strictly
/// ordered together. The keyboard (which opens a human-input channel of its
/// own), the hardware buttons, and rotation each get a pump of their own, so
/// they proceed concurrently with touch while staying ordered within
/// themselves. See `ChannelPump` for why actor isolation alone is not enough.
///
/// The relay never tears its channels down on demand: it releases them from its
/// own `deinit`, so an in-flight gesture that captured the relay finishes its
/// remaining reports (the `DeviceBackend` shutdown contract) before the channels
/// close.
package actor InteractionRelay: InteractionRelaying {
    package nonisolated let support: InteractionSupport

    private let channels: DeviceChannels
    private let touchChannel: DeviceChannel
    private let buttonChannel: DeviceChannel?
    private let keyboard: VirtualKeyboard

    // Touch and the App Switcher share this pump because they share
    // `touchChannel`; keyboard, buttons, and rotation each get their own.
    private let humanInputPump = ChannelPump()
    private let keyboardPump = ChannelPump()
    private let buttonPump = ChannelPump()
    private let rotationPump = ChannelPump()

    private init(
        channels: DeviceChannels,
        touchChannel: DeviceChannel,
        buttonChannel: DeviceChannel?,
        support: InteractionSupport,
        diagnostics: (@Sendable (String) -> Void)?
    ) {
        self.channels = channels
        self.touchChannel = touchChannel
        self.buttonChannel = buttonChannel
        self.support = support
        self.keyboard = VirtualKeyboard(channels: channels, diagnostics: diagnostics)
    }

    deinit {
        // Release the channels via the relay's own lifetime. Every submitted job
        // captures `self`, so it retains the relay until it completes: `deinit`
        // therefore runs only once no pump work is outstanding (a captured
        // in-flight gesture always finishes first). Finish the streams to retire
        // the now-idle workers, then close the channels to retire the connections.
        humanInputPump.finish()
        keyboardPump.finish()
        buttonPump.finish()
        rotationPump.finish()
        touchChannel.close()
        buttonChannel?.close()
        keyboard.close()
    }

    /// Build a relay from a device's channels: open the human-input surface
    /// (required for touch and keyboard), open hardware controls best-effort
    /// (buttons), and note whether device control (rotation) is available. The
    /// keyboard's own channel opens lazily on the first key; rotation opens a
    /// fresh channel per request.
    package static func make(
        channels: DeviceChannels,
        diagnostics: (@Sendable (String) -> Void)? = nil
    ) async throws -> InteractionRelay {
        let touchChannel = try await channels.open(.humanInput)
        let buttonChannel = await channels.openIfAvailable(.hardwareControls)
        let support = InteractionSupport(
            touch: true,
            keyboard: true,
            buttons: buttonChannel != nil,
            rotation: channels.supports(.deviceControl)
        )
        return InteractionRelay(
            channels: channels,
            touchChannel: touchChannel,
            buttonChannel: buttonChannel,
            support: support,
            diagnostics: diagnostics
        )
    }

    @discardableResult
    package func perform(_ intent: InteractionIntent) async throws -> InteractionOutcome {
        switch intent {
        case let .touch(input):
            return try await humanInputPump.run { try await self.sendTouch(input) }

        case let .keyDown(input):
            return try await keyboardPump.run { await self.keyboard.press(input.usage); return .acknowledged }

        case let .keyUp(input):
            return try await keyboardPump.run { await self.keyboard.release(input.usage); return .acknowledged }

        case let .button(input):
            return try await buttonPump.run { try await self.sendButton(input) }

        case let .rotate(input):
            return try await rotationPump.run { try await self.sendRotation(input) }
        }
    }

    // MARK: Touch

    nonisolated private func sendTouch(_ input: TouchInput) async throws -> InteractionOutcome {
        let state = input.phase == .contact ? HIDReports.contactState : HIDReports.releaseState
        switch input.kind {
        case .direct:
            let report = HIDReports.touchscreenReport(
                state: state,
                x: TouchScale.native(input.point.x),
                y: TouchScale.native(input.point.y),
                timestamp: HIDReports.machTicks()
            )
            try await touchChannel.emit(HIDReports.sendReport(report, to: HIDReports.mainTouchscreenServiceID))

        case let .systemGesture(edge):
            try await sendGestureContact(
                state: state,
                x: TouchScale.native(input.point.x),
                y: TouchScale.native(input.point.y),
                edge: edge
            )

        case let .appSwitcher(edge):
            try await runAppSwitcher(edge: edge)
        }
        return .acknowledged
    }

    /// One system-gesture report: the enriched touchscreen report carrying the
    /// edge trailer and a nanosecond timestamp, so it reaches SpringBoard's
    /// recognizer rather than the foreground app.
    nonisolated private func sendGestureContact(
        state: UInt8,
        x: UInt16,
        y: UInt16,
        edge: GestureEdge
    ) async throws {
        let report = HIDReports.touchscreenReport(
            state: state,
            x: x,
            y: y,
            timestamp: HIDReports.machNanoseconds(),
            trailer: edge.trailer
        )
        try await touchChannel.emit(HIDReports.sendReport(report, to: HIDReports.mainTouchscreenServiceID))
    }

    /// The scripted App Switcher swipe: grab the home indicator, ramp ~1/5 in
    /// toward centre, dwell so the switcher fans out (too short flicks Home),
    /// then lift. The default grab/ramp/dwell counts are tuned for portrait
    /// gesture recognition; the geometry rotates with the device through the
    /// edge's grab/dwell points.
    nonisolated private func runAppSwitcher(
        edge: GestureEdge,
        grabFrames: Int = 3,
        rampFrames: Int = 8,
        holdFrames: Int = 4,
        frameNanos: UInt64 = 10_000_000,
        pacer: any RelayPacing = SystemRelayPacer()
    ) async throws {
        let grab = edge.grabPoint
        let dwell = edge.dwellPoint
        let trajectory = AppSwitcherTrajectory.points(
            grab: grab,
            dwell: dwell,
            grabFrames: grabFrames,
            rampFrames: rampFrames,
            holdFrames: holdFrames
        )
        // The App Switcher is a self-contained trajectory that ends in its
        // own lift, and the daemon tracks it as *self-releasing* (never
        // held). So a mid-trajectory failure must still try to lift the
        // contact, because a partial gesture strands a held touch nothing can
        // release. The error path attempts the release best-effort: if that
        // attempt also fails, the contact stays stranded and quiesce can't
        // recover it.
        do {
            try await sendGestureContact(state: HIDReports.contactState, x: grab.x, y: grab.y, edge: edge)
            // Anchor after the grab lands, so the trajectory's frames are
            // scheduled from established contact rather than from the send.
            let anchor = pacer.now()
            // Every frame is sent, even when a wake runs late. The paced
            // `pane.input.*` gestures skip late samples because their points
            // are absolute, so a dropped one costs only report density. Here
            // the counts carry the meaning: drop the dwell frames and the
            // switcher never fans out, which is the flick-to-Home this
            // trajectory was tuned to avoid. Deadlines are still absolute, so
            // lateness doesn't compound across frames.
            for (index, point) in trajectory.enumerated() {
                await pacer.sleep(until: anchor + .nanoseconds(frameNanos * UInt64(index + 1)))
                try await sendGestureContact(
                    state: HIDReports.contactState,
                    x: point.x,
                    y: point.y,
                    edge: edge
                )
            }
            // The final lift is inside the guarded block too, so if *it*
            // fails the catch still retries a release. Otherwise a failed
            // final lift would strand the contact (the daemon never tracks
            // `.appSwitcher` as held, so quiesce can't recover it).
            try await sendGestureContact(state: HIDReports.releaseState, x: dwell.x, y: dwell.y, edge: edge)
        } catch {
            try? await sendGestureContact(state: HIDReports.releaseState, x: dwell.x, y: dwell.y, edge: edge)
            throw error
        }
    }

    // MARK: Buttons

    nonisolated private func sendButton(_ input: ButtonInput) async throws -> InteractionOutcome {
        guard let buttonChannel else { return .acknowledged }
        let (usagePage, usageCode) = usage(for: input.control)
        let state: UInt64 = input.phase == .press ? 1 : 2
        try await buttonChannel.emit(HIDReports.buttonEvent(state: state, usagePage: usagePage, usageCode: usageCode))
        return .acknowledged
    }

    /// Consumer-page HID usage for a control. There is no separate side-button
    /// case: on a Face-ID device the side button *is* the power button, so the
    /// daemon folds both onto `.power` before the intent gets here.
    nonisolated private func usage(for control: ButtonInput.Control) -> (page: UInt16, code: UInt16) {
        switch control {
        case .home:
            (0x0C, 0x40)

        case .power:
            (0x0C, 0x30)

        case .assistant:
            (0x0C, 0xCF)
        }
    }

    // MARK: Rotation

    nonisolated private func sendRotation(_ input: RotationInput) async throws -> InteractionOutcome {
        // The device serves one orientation request per channel, so open a fresh
        // device-control channel for each step.
        let channel = try await channels.open(.deviceControl)
        defer { channel.close() }
        let reply = try await channel.request(HIDReports.orientationRequest(input.rawValue))
        return .orientation(reply.firstValue(under: "currentDeviceOrientation")?.text)
    }
}
