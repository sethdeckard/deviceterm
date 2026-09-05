// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

/// The periodic self-check that writes down what the daemon is holding.
///
/// The counts themselves belong to the actors that keep them; what is pinned
/// here is that a sample reaches the log intact, on a cadence, and that the
/// escalation reads off the footprint rather than off any of the depths.
struct DaemonFootprintMonitorTests {
    /// Reports captured off the monitor's isolation.
    ///
    /// `@unchecked Sendable`: every access goes through `lock`.
    private final class ReportSink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [(line: String, escalated: Bool)] = []

        var count: Int { lock.withLock { lines.count } }
        var isEmpty: Bool { lock.withLock { lines.isEmpty } }
        var last: (line: String, escalated: Bool)? { lock.withLock { lines.last } }

        func record(_ line: String, _ escalated: Bool) {
            lock.withLock { lines.append((line, escalated)) }
        }
    }

    private func monitor(
        _ sink: ReportSink,
        sample: DaemonFootprintSample,
        intervalSeconds: Double = 60,
        escalationBytes: UInt64 = DaemonFootprintMonitor.defaultEscalationBytes
    ) -> DaemonFootprintMonitor {
        DaemonFootprintMonitor(
            intervalSeconds: intervalSeconds,
            escalationBytes: escalationBytes,
            sample: { sample },
            report: { line, escalated in sink.record(line, escalated) }
        )
    }

    @Test
    func aSampleCarriesEveryCountIntoOneLine() async {
        // If a count is missing, `log show` cannot attribute growth to that
        // path.
        let sink = ReportSink()
        let sample = DaemonFootprintSample(
            footprintBytes: 3 * 1_048_576,
            panes: 2,
            retiringPanes: 13,
            subscribers: 3,
            pendingPaneEvents: 4,
            conflatedSurfaceNotices: 5,
            acquiresInFlight: 6,
            abandonedDeviceReads: 7,
            xpcRequestsInFlight: 8,
            xpcConnections: 9,
            surfaceExhaustionDrops: 10,
            surfaceReuseWhileInUse: 11,
            delinquentSightings: 12
        )
        await monitor(sink, sample: sample).tick()
        let line = sink.last?.line ?? ""
        for expected in [
            "footprint=3MiB", "panes=2", "retiring=13", "subs=3", "paneEventsQueued=4",
            "surfaceNoticesConflated=5", "acquiresInFlight=6", "abandonedReads=7",
            "xpcInFlight=8", "xpcConns=9", "surfaceDrops=10",
            "surfaceReuseInUse=11", "delinquentSightings=12"
        ] {
            #expect(line.contains(expected), "missing \(expected) in: \(line)")
        }
    }

    @Test
    func anUnreadableFootprintSaysSoRatherThanReportingZero() async {
        // A zero would read as a healthy daemon. `task_info` refusing is a
        // different fact and has to look different.
        let sink = ReportSink()
        await monitor(sink, sample: DaemonFootprintSample(footprintBytes: nil)).tick()
        #expect(sink.last?.line.contains("footprint=unknown") == true)
        #expect(sink.last?.escalated == false)
    }

    @Test
    func crossingTheThresholdEscalatesTheWording() async {
        let sink = ReportSink()
        await monitor(
            sink,
            sample: DaemonFootprintSample(footprintBytes: 16 * 1_073_741_824),
            escalationBytes: 8 * 1_073_741_824
        ).tick()
        #expect(sink.last?.escalated == true)
    }

    @Test
    func depthsAloneDoNotEscalate() async {
        // Escalation reads the footprint, not the queues. A pane legitimately
        // holding work is not the condition worth shouting about, and treating
        // it as one would train a reader to ignore the line.
        let sink = ReportSink()
        let busy = DaemonFootprintSample(
            footprintBytes: 64 * 1_048_576,
            pendingPaneEvents: 10_000,
            acquiresInFlight: 99,
            xpcRequestsInFlight: 5_000
        )
        await monitor(sink, sample: busy, escalationBytes: 8 * 1_073_741_824).tick()
        #expect(sink.last?.escalated == false)
    }

    @Test
    func samplingRepeatsOnTheInterval() async {
        let sink = ReportSink()
        let monitor = monitor(
            sink,
            sample: DaemonFootprintSample(footprintBytes: 1_048_576),
            intervalSeconds: 0.01
        )
        await monitor.start()
        // Bounded wait for the second sample, so a monitor that fires once and
        // stops fails here instead of passing on the first.
        var samples = 0
        for _ in 0 ..< 500 where samples < 2 {
            try? await Task.sleep(for: .milliseconds(10))
            samples = sink.count
        }
        await monitor.stop()
        #expect(samples >= 2)
    }

    @Test
    func stoppingEndsTheSampling() async {
        let sink = ReportSink()
        let monitor = monitor(
            sink,
            sample: DaemonFootprintSample(footprintBytes: 1_048_576),
            intervalSeconds: 0.01
        )
        await monitor.start()
        for _ in 0 ..< 500 where sink.count < 1 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await monitor.stop()
        let afterStop = sink.count
        try? await Task.sleep(for: .milliseconds(120))
        #expect(sink.count == afterStop)
    }

    @Test
    func aSampleStillInFlightWhenStopRunsIsNotReported() async {
        // `stop` cannot reach a sample already suspended. Without a guard the
        // reading resumes afterwards and reports, so a line lands after the
        // caller was told sampling had ended.
        let sink = ReportSink()
        let gate = SampleGate()
        let monitor = DaemonFootprintMonitor(
            intervalSeconds: 0.01,
            escalationBytes: DaemonFootprintMonitor.defaultEscalationBytes,
            sample: {
                await gate.enter()
                return DaemonFootprintSample(footprintBytes: 1_048_576)
            },
            report: { line, escalated in sink.record(line, escalated) }
        )
        await monitor.start()
        // Bounded, so a sampler that never runs fails rather than hangs.
        var entered = false
        for _ in 0 ..< 500 where !entered {
            try? await Task.sleep(for: .milliseconds(10))
            entered = await gate.hasEntered
        }
        #expect(entered)
        await monitor.stop()
        await gate.release()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sink.isEmpty)
    }

    @Test
    func aSecondStartLeavesNothingBehindForStopToMiss() async {
        // `stop` cancels the one task `start` installed. If a second start
        // replaced it, the first would keep sampling past the stop with
        // nothing holding a reference to cancel it.
        let sink = ReportSink()
        let monitor = monitor(
            sink,
            sample: DaemonFootprintSample(footprintBytes: 1_048_576),
            intervalSeconds: 0.01
        )
        await monitor.start()
        await monitor.start()
        for _ in 0 ..< 500 where sink.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await monitor.stop()
        let afterStop = sink.count
        try? await Task.sleep(for: .milliseconds(120))
        #expect(sink.count == afterStop)
    }

    @Test
    func theProcessReportsItsOwnFootprint() {
        // The one part that cannot be faked: a live `task_info` call. A test
        // process holds something, so nil or zero means the query failed.
        let bytes = ProcessFootprint.physFootprintBytes()
        #expect(bytes != nil)
        #expect((bytes ?? 0) > 0)
    }
}

/// Parks a sampler mid-tick so a test can run `stop` against a sample that is
/// genuinely in flight, rather than one that returned before `stop` was called.
private actor SampleGate {
    private var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?

    var hasEntered: Bool { entered }

    func enter() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        released = true
        waiter?.resume()
        waiter = nil
    }
}
