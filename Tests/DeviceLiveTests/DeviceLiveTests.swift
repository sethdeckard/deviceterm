// SPDX-License-Identifier: GPL-3.0-or-later

import ChannelBootstrap
import CoreGraphics
@testable import Daemon
import DaemonProtocol
import DeviceReachability
import Foundation
import InteractionRelay
import MirrorPipeline
import Testing

// Deliberate live physical-device track, NOT part of `make verify` / `make
// test` (both `--skip DeviceLiveTests`). Run via `make test-device-live`, which
// prechecks for a connected device and fails loudly if absent.
//
// These drive the daemon's `RealDeviceBackend` against real hardware. The
// hermetic suite (`RealDeviceBackendTests`) already covers the surface copy,
// button mapping, capabilities, and no-device error paths; what only a connected
// device can prove:
//   1. deviceterm brings the CoreDevice tunnel up *itself* (no Device Hub),
//   2. the device's channels bootstrap through directory discovery (production
//      requires only mirror + human input; this test device also vends the
//      optional hardware-control and device-control roles), and
//   3. frames actually decode and flow through the owned-surface ring.
//
// The track NEVER reboots or shuts down the device. Prerequisites: an iPhone/iPad
// plugged in, unlocked, and trusted, with Device Hub / Xcode's "Devices and
// Simulators" window **closed**. The whole point is that deviceterm holds the
// tunnel up on its own (via `TunnelKeepalive`); a Device-Hub "view screen" would
// also consume the single video stream the mirror needs.

/// Frame tally the `@Sendable` surface callback bumps from arbitrary tasks.
private actor FrameSink {
    private(set) var received = 0
    func bump() { received += 1 }
}

/// Stores terminal-failure reasons reported by the pipeline.
///
/// A queue rather than an actor because `onFatal` is synchronous: hopping
/// through an unstructured `Task` would let a reason still be in flight when a
/// test reads the list, and this list is read to assert it is *empty*, which is
/// the direction that lag would silently favor. (`FrameSink` above is polled
/// until non-zero, so the same lag is harmless there.)
///
/// `@unchecked Sendable`: `storage` is reached only inside `queue`.
private final class FatalSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.deviceterm.tests.fatal-sink")
    private var storage: [String] = []

    var reasons: [String] { queue.sync { storage } }

    func record(_ reason: String) { queue.sync { storage.append(reason) } }
}

/// Poll an async predicate until it's true or the attempts run out.
private func waitUntil(attempts: Int, interval: Duration, _ predicate: @Sendable () async -> Bool) async throws {
    for _ in 0..<attempts {
        if await predicate() { return }
        try await Task.sleep(for: interval)
    }
}

/// Resolve the sole connected device to a live backend (which brings the tunnel
/// up via the keepalive), run `body`, then **always** shut the backend down and
/// release the keepalive so no `devicectl` is orphaned.
private func withDeviceBackend<T>(_ body: (RealDeviceBackend) async throws -> T) async throws -> T {
    let coordinator = PhysicalDeviceCoordinator()
    let device = try #require(await coordinator.enumerate().first)
    let backend = try await coordinator.resolveBackend(deviceId: device.deviceId)
    do {
        let result = try await body(backend)
        backend.shutdownBackend()
        await coordinator.releaseKeepalive(deviceId: device.deviceId)
        return result
    } catch {
        backend.shutdownBackend()
        await coordinator.releaseKeepalive(deviceId: device.deviceId)
        throw error
    }
}

/// Bring the device's tunnel up the way production attach does (borrowing
/// `devicectl` via the keepalive), bootstrap its channels, and hand them to
/// `body`, then release the keepalive. Proves deviceterm holds the tunnel itself,
/// Device Hub closed.
private func withDeviceChannels<T>(
    _ body: (PhysicalDeviceCoordinator, PhysicalDeviceInfo, DeviceRoute, DeviceChannels) async throws -> T
) async throws -> T {
    let keepalive = TunnelKeepalive()
    let coordinator = PhysicalDeviceCoordinator(keepalive: keepalive)
    let device = try #require(await coordinator.enumerate().first)
    keepalive.retain(udid: device.deviceId)
    do {
        let route = try await coordinator.resolveRoute(deviceId: device.deviceId)
        let channels = try await ChannelBroker.bootstrap(route: route)
        let result = try await body(coordinator, device, route, channels)
        keepalive.release(udid: device.deviceId)
        return result
    } catch {
        keepalive.release(udid: device.deviceId)
        throw error
    }
}

@Suite(.serialized)
struct DeviceLiveTests {
    @Test
    func enumeratesAtLeastOneConnectedDevice() async {
        let devices = await PhysicalDeviceCoordinator().enumerate()
        #expect(!devices.isEmpty, "no connected device — the track precheck should have caught this")
    }

    @Test
    func bootstrapsChannelsForEveryRequiredRole() async throws {
        // deviceterm brings the tunnel up itself, then the device's channels
        // bootstrap through directory discovery (which probes the open ports).
        // Production requires only mirror + human input; this test device also
        // vends hardware controls and device control, so all four roles are
        // expected here, plus the device's real identity.
        try await withDeviceChannels { _, _, _, channels in
            #expect(channels.supports(.mirror))
            #expect(channels.supports(.humanInput))
            #expect(channels.supports(.hardwareControls))
            #expect(channels.supports(.deviceControl))
            #expect(channels.identity.uniqueDeviceID != nil)
            #expect(channels.identity.productType != nil)
        }
    }

    @Test
    func resolvesBackendReportingDeviceCapabilities() async throws {
        // resolveBackend brings the tunnel up, bootstraps channels, and builds the
        // relay + feed. This device vends everything: touch + keyboard, buttons,
        // and rotation. Crown/accessibility have no physical-device path.
        try await withDeviceBackend { backend in
            #expect(backend.capabilities.touch)
            #expect(backend.capabilities.key)
            #expect(backend.capabilities.text)
            #expect(backend.capabilities.button)
            #expect(backend.capabilities.rotate)
            #expect(!backend.capabilities.crown)
            #expect(!backend.capabilities.accessibility)
        }
    }

    @Test
    func framesFlowThroughOwnedSurfaceRing() async throws {
        try await withDeviceBackend { backend in
            let sink = FrameSink()
            try backend.startFrames(onFrame: { _ in Task { await sink.bump() } }, onFatal: { _ in }, onDisconnect: {})
            try await waitUntil(attempts: 100, interval: .milliseconds(200)) { await sink.received > 0 }
            let received = await sink.received
            #expect(received > 0, "no frames decoded within ~20s — media / decode / owned-surface copy failed")
        }
    }

    @Test
    func feedbackLoopSustainsAStream() async throws {
        // The offer groups marker bands before ascending bitrate bands. This
        // checks that the device accepts that ordering and *sustains* the
        // stream rather than merely producing a first frame. Sustained delivery
        // is the observable: over a window, Receiver Report sends keep being
        // attempted, frames keep arriving, no session restarts, and the pipeline
        // never declares a fatal.
        //
        // The window needs no screen activity to hold: the device continues
        // encoding when the picture does not change, which is the same property
        // that lets the 5s stall watchdog treat silence as a fault rather than
        // as an idle screen. What this does rely on is the track's standing
        // prerequisite that the device is unlocked. There is no assertion on
        // PLI: it is loss-triggered, and a healthy run may never emit one.
        try await withDeviceChannels { _, _, route, channels in
            let pipeline = MirrorPipeline(route: route, channels: channels)
            // `withDeviceChannels` tears down what *it* made, and this pipeline
            // isn't that. Start its teardown before the helper releases the
            // keepalive: `stop` cancels the receive task and closes the socket
            // without waiting for the task to unwind, which is enough here. Any
            // task that briefly outlives the release has been cancelled, and its
            // current socket, if any, has been closed.
            defer { pipeline.stop() }

            let fatal = FatalSink()
            let sink = FrameSink()
            let frames = pipeline.frames(onFatal: { reason in fatal.record(reason) })
            let pump = Task { for await _ in frames { await sink.bump() } }
            defer { pump.cancel() }

            try await waitUntil(attempts: 100, interval: .milliseconds(200)) { await sink.received > 0 }
            try #require(await sink.received > 0, "no first frame within ~20s — nothing to sustain")

            // Long enough to span several Report intervals (the cadence is 1s)
            // and to outlast the 5s stall window, so a restart would show up.
            let baseline = pipeline.observation()
            try await Task.sleep(for: .seconds(8))
            let after = pipeline.observation()

            #expect(
                after.receiverReportAttempts > baseline.receiverReportAttempts,
                "no Receiver Report send was attempted in 8s — the encoder will stall and the mirror will freeze"
            )
            #expect(
                after.framesDelivered > baseline.framesDelivered,
                "no frame arrived in 8s; confirm the device is unlocked and the stream remains active"
            )
            #expect(
                after.sessionRestarts == baseline.sessionRestarts,
                "the stream ended and scheduled a restart mid-window — it is not sustaining"
            )
            let reasons = fatal.reasons
            #expect(reasons.isEmpty, "pipeline reported fatal: \(reasons)")
        }
    }

    @Test
    func backendDeliversTouchUnderActiveStream() async throws {
        // With a stream up (auth gate open), a tap enqueued through the backend's
        // pump must reach the human-input channel without error. HID reports are
        // fire-and-forget, so visual landing is the manual step; this proves the
        // wire path doesn't throw.
        try await withDeviceBackend { backend in
            let sink = FrameSink()
            try backend.startFrames(onFrame: { _ in Task { await sink.bump() } }, onFatal: { _ in }, onDisconnect: {})
            try await waitUntil(attempts: 100, interval: .milliseconds(200)) { await sink.received > 0 }
            try #require(await sink.received > 0, "stream never produced a frame")
            try backend.tapDown(at: CGPoint(x: 0.5, y: 0.5), generation: backend.currentInputGeneration())
            try backend.tapUp(at: CGPoint(x: 0.5, y: 0.5), generation: backend.currentInputGeneration())
            try await Task.sleep(for: .seconds(1))
        }
    }

    @Test
    func pressesHardwareHomeButton() async throws {
        // Buttons go through the hardware-controls channel and need no media
        // stream. The device vends it, so the backend reports button = true and a
        // Home press must enqueue + send without error. Visible effect (home
        // screen) is the manual confirmation.
        try await withDeviceBackend { backend in
            #expect(backend.capabilities.button)
            try backend.pressHardwareButton(.home, generation: backend.currentInputGeneration())
            try await Task.sleep(for: .seconds(1)) // let press → hold → release drain
        }
    }

    @Test
    func rotatesDeviceOrientation() async throws {
        // Rotation goes through the device-control channel (no media stream; a
        // fresh channel per request). Each relative step returns the resulting
        // absolute orientation, so assert two lefts land on *different* orientations
        // (proof the device rotated, not a swallowed error), then drive the
        // backend's absolute rotate back to portrait to leave the device upright.
        try await withDeviceChannels { coordinator, device, _, channels in
            let relay = try await InteractionRelay.make(channels: channels)
            let first = try await relay.perform(.rotate(.left))
            let second = try await relay.perform(.rotate(.left))
            guard case let .orientation(firstName) = first, case let .orientation(secondName) = second else {
                Issue.record("rotate did not report an orientation")
                return
            }
            // Both steps must report a concrete orientation before comparing them,
            // so a malformed second reply can't slip through on a non-nil first.
            let landedFirst = try #require(firstName, "no orientation in first reply — envelope wrong")
            let landedSecond = try #require(secondName, "no orientation in second reply — envelope wrong")
            #expect(landedFirst != landedSecond, "two lefts should report different orientations")

            let backend = try await coordinator.resolveBackend(deviceId: device.deviceId)
            #expect(backend.capabilities.rotate)
            _ = try await backend.rotate(to: .portrait, generation: backend.currentInputGeneration())
            try await Task.sleep(for: .seconds(4)) // let the steps round-trip
            backend.shutdownBackend()
            await coordinator.releaseKeepalive(deviceId: device.deviceId)
        }
    }

    @Test
    func typesThroughVirtualKeyboard() async throws {
        // Keyboard goes through the human-input channel's virtual keyboard
        // (registered lazily on the first key, once the media-stream auth gate is
        // open). This drives the real backend keyDown/keyUp path with a stream
        // running and asserts it enqueues without error. Visible characters need a
        // focused text field (manual). Type "hi": KEY_H=0x0B, KEY_I=0x0C.
        try await withDeviceBackend { backend in
            #expect(backend.capabilities.key)
            #expect(backend.capabilities.text)
            let sink = FrameSink()
            try backend.startFrames(onFrame: { _ in Task { await sink.bump() } }, onFatal: { _ in }, onDisconnect: {})
            try await waitUntil(attempts: 100, interval: .milliseconds(200)) { await sink.received > 0 }
            try #require(await sink.received > 0, "no frames — keyboard auth gate stays closed")
            for usage: UInt32 in [0x0B, 0x0C] {
                try backend.keyDown(hidUsage: usage, generation: backend.currentInputGeneration())
                try await Task.sleep(for: .milliseconds(80))
                try backend.keyUp(hidUsage: usage, generation: backend.currentInputGeneration())
                try await Task.sleep(for: .milliseconds(80))
            }
            try await Task.sleep(for: .seconds(1)) // let the key pump drain
        }
    }
}
