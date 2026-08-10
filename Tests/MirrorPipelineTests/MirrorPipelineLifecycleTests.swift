// SPDX-License-Identifier: GPL-3.0-or-later

import ChannelBootstrap
import DeviceReachability
import Foundation
import Testing

@testable import MirrorPipeline

/// The feed lifecycle state machine, `idle → running → (stopped | failed)`,
/// driven without a device. Channels vend no mirror role, so each session ends
/// immediately (the mirror channel can't open), which lets the restart/terminal
/// paths run fast and hermetically.
struct MirrorPipelineLifecycleTests {
    private actor FatalLog {
        private(set) var reasons: [String] = []
        func record(_ reason: String) { reasons.append(reason) }
    }

    private func route() -> DeviceRoute {
        DeviceRoute(deviceId: "U", interfaceName: "utun9", hostAddress: "fd00::2", deviceAddress: "fd00::1")
    }

    /// Channels with no mirror role, so `open(.mirror)` fails fast.
    private func channelsWithoutMirror() -> DeviceChannels {
        DeviceChannels(
            deviceAddress: "fd00::1",
            ports: [:],
            identity: DeviceIdentity(uniqueDeviceID: "U", productType: nil, osVersion: nil, marketingName: nil)
        )
    }

    private func waitUntil(_ predicate: @Sendable () async -> Bool, within: Duration = .seconds(2)) async throws {
        let deadline = ContinuousClock().now.advanced(by: within)
        while ContinuousClock().now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("stop while idle finishes a subsequently requested stream")
    func stopWhileIdle() async {
        let pipeline = MirrorPipeline(route: route(), channels: channelsWithoutMirror())
        pipeline.stop() // idle → stopped, no receive task
        let stream = pipeline.frames(onFatal: { _ in })
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil) // already finished
    }

    @Test("repeated stop is idempotent")
    func repeatedStop() {
        let pipeline = MirrorPipeline(route: route(), channels: channelsWithoutMirror())
        pipeline.stop()
        pipeline.stop()
        pipeline.stop() // no crash, no state churn
    }

    @Test("a voluntary stop never fires onFatal")
    func voluntaryStopNoFatal() async throws {
        let log = FatalLog()
        let pipeline = MirrorPipeline(route: route(), channels: channelsWithoutMirror())
        let stream = pipeline.frames(onFatal: { reason in Task { await log.record(reason) } })
        pipeline.stop()
        // Drain the (finished) stream and give any stray fatal a chance to fire.
        for await _ in stream {}
        try await Task.sleep(for: .milliseconds(100))
        #expect(await log.reasons.isEmpty)
    }

    @Test("terminal failure fires onFatal exactly once and finishes the stream")
    func terminalFailureFiresOnce() async throws {
        let log = FatalLog()
        let pipeline = MirrorPipeline(
            route: route(),
            channels: channelsWithoutMirror(),
            emptyRestartLimit: 1,
            restartBackoff: .milliseconds(1)
        )
        let stream = pipeline.frames(onFatal: { reason in Task { await log.record(reason) } })
        // The one empty session exhausts the restart cap → terminal failure.
        for await _ in stream {} // finishes when the pipeline fails
        try await waitUntil { await log.reasons.count == 1 }
        #expect(await log.reasons.count == 1)

        // A stop after a terminal failure fires no second fatal.
        pipeline.stop()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await log.reasons.count == 1)
    }

    @Test("a second frames() after a terminal state returns a finished stream without re-arming onFatal")
    func secondFramesAfterTerminal() async throws {
        let log = FatalLog()
        let pipeline = MirrorPipeline(
            route: route(),
            channels: channelsWithoutMirror(),
            emptyRestartLimit: 1,
            restartBackoff: .milliseconds(1)
        )
        for await _ in pipeline.frames(onFatal: { reason in Task { await log.record(reason) } }) {}
        try await waitUntil { await log.reasons.count == 1 }

        // Re-obtaining the stream after failure yields an already-finished stream
        // and must not arm (or call) the new fatal callback.
        let second = pipeline.frames(onFatal: { _ in Task { await log.record("second") } })
        var iterator = second.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        try await Task.sleep(for: .milliseconds(50))
        // Still just the one terminal reason; the second callback was never armed.
        #expect(await log.reasons.count == 1)
        #expect(!(await log.reasons.contains("second")))
    }
}
