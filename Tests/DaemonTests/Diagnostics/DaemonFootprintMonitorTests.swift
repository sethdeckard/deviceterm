// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

/// The periodic self-check that writes down what the daemon is holding.
///
/// The counts themselves belong to the actors that keep them; what is pinned
/// here is that a sample reaches the log intact, on a cadence, that the
/// escalation reads off the footprint rather than off any of the depths, and
/// that the ceiling ends sampling and hands off exactly once, with the
/// breakdown written first.
struct DaemonFootprintMonitorTests {
    private typealias Report = DaemonFootprintMonitor.Report

    /// Reports captured off the monitor's isolation.
    ///
    /// `@unchecked Sendable`: every access goes through `lock`.
    private final class ReportSink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [(line: String, kind: Report)] = []

        var count: Int { lock.withLock { lines.count } }
        var isEmpty: Bool { lock.withLock { lines.isEmpty } }
        var last: (line: String, kind: Report)? { lock.withLock { lines.last } }
        var all: [(line: String, kind: Report)] { lock.withLock { lines } }
        var kinds: [Report] { lock.withLock { lines.map(\.kind) } }

        func record(_ line: String, _ kind: Report) {
            lock.withLock { lines.append((line, kind)) }
        }
    }

    /// Counts calls made from a synchronous `@Sendable` closure.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0

        var total: Int { lock.withLock { calls } }

        func increment() {
            lock.withLock { calls += 1 }
        }
    }

    /// The terminate handler's reasons, one per hand-off.
    private actor ReasonBox {
        private(set) var reasons: [String] = []

        func record(_ reason: String) { reasons.append(reason) }
    }

    private static let gibibyte: UInt64 = 1_073_741_824

    private func monitor(
        _ sink: ReportSink,
        sample: DaemonFootprintSample,
        intervalSeconds: Double = 60,
        escalationBytes: UInt64 = DaemonFootprintMonitor.defaultEscalationBytes,
        ceilingBytes: UInt64? = nil,
        breakdown: [String] = [],
        terminate: ReasonBox? = nil
    ) -> DaemonFootprintMonitor {
        DaemonFootprintMonitor(
            intervalSeconds: intervalSeconds,
            escalationBytes: escalationBytes,
            ceilingBytes: ceilingBytes,
            sample: { sample },
            breakdown: { breakdown },
            report: { line, kind in sink.record(line, kind) },
            terminate: { reason in await terminate?.record(reason) }
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
            delinquentSightings: 12,
            inputSubmissions: 14
        )
        await monitor(sink, sample: sample).tick()
        let line = sink.last?.line ?? ""
        for expected in [
            "footprint=3MiB", "panes=2", "retiring=13", "subs=3", "paneEventsQueued=4",
            "surfaceNoticesConflated=5", "acquiresInFlight=6", "abandonedReads=7",
            "xpcInFlight=8", "xpcConns=9", "surfaceDrops=10",
            "surfaceReuseInUse=11", "delinquentSightings=12", "inputSends=14"
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
        #expect(sink.last?.kind == .sample)
    }

    @Test
    func crossingTheThresholdEscalatesTheWording() async {
        let sink = ReportSink()
        await monitor(
            sink,
            sample: DaemonFootprintSample(footprintBytes: 16 * Self.gibibyte),
            escalationBytes: 8 * Self.gibibyte
        ).tick()
        #expect(sink.last?.kind == .high)
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
        await monitor(sink, sample: busy, escalationBytes: 8 * Self.gibibyte).tick()
        #expect(sink.last?.kind == .sample)
    }

    @Test
    func theFirstEscalatedTickLogsABreakdownOnce() async {
        // One breakdown when the footprint first crosses the escalation line
        // while still below the ceiling, so a later breach has something to be
        // compared against. Not one per tick: a daemon that sits above the
        // line for hours would otherwise fill the log with multi-line dumps.
        let sink = ReportSink()
        let monitor = monitor(
            sink,
            sample: DaemonFootprintSample(footprintBytes: Self.gibibyte + Self.gibibyte / 2),
            escalationBytes: Self.gibibyte,
            breakdown: ["where"]
        )
        await monitor.tick()
        await monitor.tick()
        await monitor.tick()
        #expect(sink.kinds == [.high, .breakdown, .high, .high])
        #expect(sink.all[1].line == "where")
    }

    @Test
    func theBreakdownIsNotReadPerTick() async {
        // The region walk makes a Mach call per visited region. A quiet daemon
        // must never pay it on the cadence.
        let sink = ReportSink()
        let counter = CallCounter()
        let monitor = DaemonFootprintMonitor(
            escalationBytes: Self.gibibyte,
            ceilingBytes: 2 * Self.gibibyte,
            sample: { DaemonFootprintSample(footprintBytes: 64 * 1_048_576) },
            breakdown: {
                counter.increment()
                return []
            },
            report: { line, kind in sink.record(line, kind) }
        )
        await monitor.tick()
        await monitor.tick()
        await monitor.tick()
        #expect(counter.total == 0)
        #expect(sink.count == 3)
    }

    @Test
    func reachingTheCeilingTerminatesOnce() async {
        let sink = ReportSink()
        let reasons = ReasonBox()
        let monitor = monitor(
            sink,
            sample: DaemonFootprintSample(footprintBytes: 2 * Self.gibibyte + 1_048_576),
            ceilingBytes: 2 * Self.gibibyte,
            terminate: reasons
        )
        await monitor.tick()
        let afterBreach = sink.count
        await monitor.tick()
        #expect(await reasons.reasons.count == 1)
        #expect(sink.count == afterBreach)
        #expect(await monitor.didBreachCeiling)
    }

    @Test
    func theReasonNamesTheReadingAndTheCeiling() async {
        // The lifecycle and stderr exit lines carry this string as their
        // record of the reading and the ceiling.
        let sink = ReportSink()
        let reasons = ReasonBox()
        await monitor(
            sink,
            sample: DaemonFootprintSample(footprintBytes: 2 * Self.gibibyte + 1_048_576),
            ceilingBytes: 2 * Self.gibibyte,
            terminate: reasons
        ).tick()
        let reason = await reasons.reasons.first ?? ""
        #expect(reason.contains("footprint=2049MiB"))
        #expect(reason.contains("ceiling=2048MiB"))
    }

    @Test
    func theCeilingLogsTheBreakdownBeforeTerminating() async {
        // The breakdown is the whole point of exiting deliberately rather than
        // being killed, so it is reported before the hand-off, never after.
        let sink = ReportSink()
        let reasons = ReasonBox()
        await monitor(
            sink,
            sample: DaemonFootprintSample(footprintBytes: 3 * Self.gibibyte),
            ceilingBytes: 2 * Self.gibibyte,
            breakdown: ["vm: a", "regions: b"],
            terminate: reasons
        ).tick()
        #expect(sink.kinds == [.high, .breakdown, .breakdown])
        #expect(sink.all.map(\.line).dropFirst() == ["vm: a", "regions: b"])
        #expect(await reasons.reasons.count == 1)
    }

    @Test
    func belowTheCeilingNeverTerminates() async {
        let sink = ReportSink()
        let reasons = ReasonBox()
        let monitor = monitor(
            sink,
            sample: DaemonFootprintSample(footprintBytes: 100 * 1_048_576),
            ceilingBytes: 2 * Self.gibibyte,
            terminate: reasons
        )
        await monitor.tick()
        await monitor.tick()
        #expect(await reasons.reasons.isEmpty)
        #expect(sink.count == 2)
    }

    @Test
    func anUnreadableFootprintDoesNotTerminate() async {
        // Nil is "the kernel refused the query", not a reading. Exiting on it
        // would turn a diagnostic gap into an outage.
        let sink = ReportSink()
        let reasons = ReasonBox()
        await monitor(
            sink,
            sample: DaemonFootprintSample(footprintBytes: nil),
            ceilingBytes: 1,
            terminate: reasons
        ).tick()
        #expect(await reasons.reasons.isEmpty)
        #expect(sink.last?.kind == .sample)
    }

    @Test
    func withoutACeilingNothingTerminates() async {
        let sink = ReportSink()
        let reasons = ReasonBox()
        await monitor(
            sink,
            sample: DaemonFootprintSample(footprintBytes: 64 * Self.gibibyte),
            ceilingBytes: nil,
            terminate: reasons
        ).tick()
        #expect(await reasons.reasons.isEmpty)
        #expect(sink.last?.kind == .high)
    }

    @Test
    func theCeilingStopsSamplingBeforeItTerminates() async {
        // Once the hand-off starts, nothing else may be logged as if the
        // daemon were carrying on.
        let sink = ReportSink()
        let reasons = ReasonBox()
        let monitor = monitor(
            sink,
            sample: DaemonFootprintSample(footprintBytes: 3 * Self.gibibyte),
            intervalSeconds: 0.01,
            ceilingBytes: 2 * Self.gibibyte,
            terminate: reasons
        )
        await monitor.start()
        var handedOff = 0
        for _ in 0 ..< 500 where handedOff < 1 {
            try? await Task.sleep(for: .milliseconds(10))
            handedOff = await reasons.reasons.count
        }
        try? await Task.sleep(for: .milliseconds(120))
        #expect(await reasons.reasons.count == 1)
        #expect(sink.kinds.filter { $0 != .breakdown }.count == 1)
    }

    @Test
    func aSampleInFlightAcrossStopDoesNotTerminate() async {
        // A stop that lands while a breaching sample is suspended must win.
        // The reading belongs to a monitor the caller has already ended, and
        // exiting on it would be the second failure mode the generation guard
        // exists to prevent.
        let sink = ReportSink()
        let reasons = ReasonBox()
        let gate = SampleGate()
        let monitor = DaemonFootprintMonitor(
            intervalSeconds: 0.01,
            ceilingBytes: 2 * Self.gibibyte,
            sample: {
                await gate.enter()
                return DaemonFootprintSample(footprintBytes: 3 * Self.gibibyte)
            },
            report: { line, kind in sink.record(line, kind) },
            terminate: { reason in await reasons.record(reason) }
        )
        await monitor.start()
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
        #expect(await reasons.reasons.isEmpty)
    }

    @Test
    func startAfterABreachIsANoOp() async {
        let sink = ReportSink()
        let reasons = ReasonBox()
        let monitor = monitor(
            sink,
            sample: DaemonFootprintSample(footprintBytes: 3 * Self.gibibyte),
            intervalSeconds: 0.01,
            ceilingBytes: 2 * Self.gibibyte,
            terminate: reasons
        )
        await monitor.tick()
        let afterBreach = sink.count
        await monitor.start()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sink.count == afterBreach)
        #expect(await reasons.reasons.count == 1)
    }

    @Test("the ceiling reads from the environment", arguments: [
        (nil, 2 * 1_073_741_824),
        ("0", nil),
        ("512", 512 * 1_048_576),
        ("abc", 2 * 1_073_741_824),
        ("-5", 2 * 1_073_741_824),
        ("99999999999999999999", 2 * 1_073_741_824)
    ] as [(String?, UInt64?)])
    func theCeilingReadsFromTheEnvironment(raw: String?, expected: UInt64?) {
        var environment: [String: String] = [:]
        if let raw {
            environment[DeviceTermEnv.footprintCeilingMiB] = raw
        }
        #expect(DaemonFootprintMonitor.ceilingBytes(environment: environment) == expected)
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
            report: { line, kind in sink.record(line, kind) }
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

    @Test
    func theProcessReportsExtendedVMInfo() {
        // The related counters come from the same call. A test process has
        // dirtied anonymous memory, so a zero means the field was not read.
        let info = ProcessFootprint.vmInfo()
        #expect(info != nil)
        #expect((info?.internalBytes ?? 0) > 0)
        #expect((info?.pageSize ?? 0) > 0)
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
