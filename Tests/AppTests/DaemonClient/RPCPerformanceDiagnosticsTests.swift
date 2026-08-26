// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Testing

@MainActor
private final class RPCDiagnosticsTestClock {
    var now: UInt64

    init(now: UInt64) {
        self.now = now
    }
}

/// Compact per-method/lane aggregates retain
/// reply, timeout, failure, and elapsed-time accounting without request data.
@MainActor
struct RPCPerformanceDiagnosticsTests {
    @Test
    func aggregatesByMethodAndLane() {
        let clock = RPCDiagnosticsTestClock(now: 1_000_000_000)
        let diagnostics = RPCPerformanceDiagnostics(
            summaryIntervalNanoseconds: .max,
            automaticallyEmitSummaries: false,
            clock: { clock.now }
        )
        let firstStart = diagnostics.now()
        clock.now += 20_000_000
        diagnostics.record(
            method: .deviceList,
            lane: .control,
            startedAtNanoseconds: firstStart,
            outcome: .reply,
            severeDelayNanoseconds: 1_000_000_000
        )
        let secondStart = diagnostics.now()
        clock.now += 50_000_000
        diagnostics.record(
            method: .deviceList,
            lane: .control,
            startedAtNanoseconds: secondStart,
            outcome: .timeout,
            severeDelayNanoseconds: 1_000_000_000
        )
        let paneStart = diagnostics.now()
        clock.now += 5_000_000
        diagnostics.record(
            method: .paneSubscribe,
            lane: .pane,
            startedAtNanoseconds: paneStart,
            outcome: .transport,
            severeDelayNanoseconds: 1_000_000_000
        )

        #expect(
            diagnostics.bucketsForTesting()["control:device.list"]
                == RPCPerformanceBucket(
                    calls: 2,
                    replies: 1,
                    timeouts: 1,
                    failures: 0,
                    totalMilliseconds: 70,
                    maximumMilliseconds: 50
                )
        )
        #expect(
            diagnostics.bucketsForTesting()["pane:pane.subscribe"]
                == RPCPerformanceBucket(
                    calls: 1,
                    replies: 0,
                    timeouts: 0,
                    failures: 1,
                    totalMilliseconds: 5,
                    maximumMilliseconds: 5
                )
        )
    }

    @Test
    func summaryTickFlushesABurstDuringInactivity() {
        let clock = RPCDiagnosticsTestClock(now: 0)
        let diagnostics = RPCPerformanceDiagnostics(
            summaryIntervalNanoseconds: 100,
            automaticallyEmitSummaries: false,
            clock: { clock.now }
        )
        let startedAt = diagnostics.now()
        clock.now = 20

        diagnostics.record(
            method: .daemonPing,
            lane: .control,
            startedAtNanoseconds: startedAt,
            outcome: .reply,
            severeDelayNanoseconds: .max
        )
        #expect(diagnostics.bucketsForTesting()["control:daemon.ping"]?.calls == 1)

        clock.now = 100
        diagnostics.emitSummaryForTesting()

        #expect(diagnostics.bucketsForTesting().isEmpty)
    }

    @Test
    func delayedRequestStartsANewWindow() {
        let clock = RPCDiagnosticsTestClock(now: 0)
        let diagnostics = RPCPerformanceDiagnostics(
            summaryIntervalNanoseconds: 100,
            automaticallyEmitSummaries: false,
            clock: { clock.now }
        )
        diagnostics.record(
            method: .deviceList,
            lane: .control,
            startedAtNanoseconds: 0,
            outcome: .reply,
            severeDelayNanoseconds: .max
        )
        clock.now = 110

        diagnostics.record(
            method: .daemonPing,
            lane: .control,
            startedAtNanoseconds: 100,
            outcome: .reply,
            severeDelayNanoseconds: .max
        )

        #expect(diagnostics.bucketsForTesting()["control:device.list"] == nil)
        #expect(diagnostics.bucketsForTesting()["control:daemon.ping"]?.calls == 1)
    }

    @Test
    func scheduledSummaryFlushesWithoutAnotherRequest() async throws {
        let diagnostics = RPCPerformanceDiagnostics(
            summaryIntervalNanoseconds: 5_000_000
        )
        diagnostics.record(
            method: .daemonPing,
            lane: .control,
            startedAtNanoseconds: diagnostics.now(),
            outcome: .reply,
            severeDelayNanoseconds: .max
        )

        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(diagnostics.bucketsForTesting().isEmpty)
    }
}
