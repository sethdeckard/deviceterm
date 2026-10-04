// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOSurface
import os

/// Copies only dirty frames, with a fixed ceiling and no timer while idle.
struct SimFramePump: Sendable {
    struct Timing: Sendable {
        var interval: Duration = .nanoseconds(16_666_667)
        var recoveryDelay: Duration = .seconds(2)
        var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
        var sleep: @Sendable (ContinuousClock.Instant) async throws -> Void = {
            try await ContinuousClock().sleep(until: $0)
        }
    }

    /// Off-by-default frame measurement. Non-nil is the on switch: without
    /// it the pump reads no metrics clocks and builds no accumulator.
    struct Instrumentation: Sendable {
        let sink: FrameMetricsSink
        var signposter: OSSignposter = .disabled
        var windowNanoseconds: UInt64 = 1_000_000_000
        var now: @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    }

    let signal: SimFrameSignal
    let pool: LeasedSurfacePool
    /// Where the copy into a slot runs: a dedicated queue the owner creates at
    /// `.userInteractive`, so the copy takes that QoS rather than whatever the
    /// pump task inherited, and doesn't occupy a cooperative-pool worker.
    let copyQueue: BlockingWorkQueue
    /// Copies on the GPU when set and the surfaces allow it; otherwise, and
    /// whenever a blit fails, the copy runs on `copyQueue`.
    var blitter: SurfaceBlitter?
    var timing = Timing()
    var instrumentation: Instrumentation?
    let read: @Sendable () async -> RetainedSurface?
    let publish: @Sendable (PublishedSurface) -> Void
    let fail: @Sendable (String) -> Void

    func run() async {
        var nextAttempt: ContinuousClock.Instant?
        var unavailableSince: ContinuousClock.Instant?
        // Nil unless instrumented. The first consumed update opens the window,
        // and a later one closes it, so an idle pump writes no rows and keeps
        // no timer. A window still open when the run ends is discarded.
        var metrics: FrameMetrics?
        for await _ in signal.wakes {
            do {
                if let deadline = nextAttempt, timing.now() < deadline {
                    try await timing.sleep(deadline)
                    if metrics != nil {
                        metrics?.noteWakeLate(nanoseconds: Self.nanoseconds(timing.now() - deadline))
                    }
                }
                try Task.checkCancellation()
            } catch { return }
            guard let update = signal.consume() else { continue }
            // Close the window before counting this update, so no row holds an
            // update's arrival without its outcome.
            if let instrumentation {
                metrics = await rolledWindow(metrics, instrumentation)
            }
            metrics?.noteConsumed()
            nextAttempt = Self.nextDeadline(after: nextAttempt, now: timing.now(), interval: timing.interval)
            let resolved: RetainedSurface?
            switch update {
            case let .surface(surface):
                resolved = surface

            case .invalidated:
                let resolveStart = instrumentation?.now() ?? 0
                resolved = await read()
                if let instrumentation {
                    metrics?.noteResolve(nanoseconds: instrumentation.now() &- resolveStart)
                }
            }
            if let deadline = nextAttempt {
                nextAttempt = Self.deadline(deadline, afterResolvingAt: timing.now(), interval: timing.interval)
            }
            guard let source = resolved else {
                metrics?.noteDroppedNoSurface()
                continue
            }
            guard !Task.isCancelled else { continue }
            let now = timing.now()
            let dims = source.withRef { (IOSurfaceGetWidth($0), IOSurfaceGetHeight($0)) }
            if metrics != nil {
                // A simulator surface has no padding to crop, so the content is
                // the whole source.
                let format = source.withRef { IOSurfaceGetPixelFormat($0) }
                metrics?.noteGeometry(
                    sourceWidth: dims.0,
                    sourceHeight: dims.1,
                    contentWidth: dims.0,
                    contentHeight: dims.1,
                    pixelFormat: format
                )
            }
            guard let published = await pool.acquire(width: dims.0, height: dims.1) else {
                metrics?.noteDroppedExhaustion()
                if unavailableSince == nil { unavailableSince = now }
                if let since = unavailableSince, now - since >= timing.recoveryDelay {
                    unavailableSince = nil
                    switch await pool.recoverFromExhaustion() {
                    case .recovered:
                        DiagnosticLog.attach.notice("surface pool unavailable; recovery will retry on the next frame")

                    case .exhausted:
                        fail("surface pool stayed unavailable after recovery; the mirror can't continue")
                        return
                    }
                }
                continue
            }
            unavailableSince = nil
            guard !Task.isCancelled else { return }
            let copyStart = instrumentation?.now() ?? 0
            let copyInterval = instrumentation?.signposter.beginInterval("copy")
            let copied = await Self.timedCopy(
                from: source,
                to: published,
                on: copyQueue,
                blitter: blitter,
                measuring: instrumentation != nil
            )
            if let instrumentation, let copyInterval {
                instrumentation.signposter.endInterval("copy", copyInterval)
                metrics?.noteCopy(nanoseconds: instrumentation.now() &- copyStart, bytes: copied.bytes)
                metrics?.noteCopyCPU(nanoseconds: copied.cpuNanoseconds)
            }
            guard !Task.isCancelled else { return }
            publish(published)
            metrics?.notePublished()
        }
    }

    /// Open the first window, or close one that has run its length: record its
    /// summary with the pool's hold ages and occupancy, then start the next.
    ///
    /// The pool outlives a run, so opening the first window discards the hold
    /// ages it accumulated before this run (acknowledgements from a paused
    /// period or an earlier run's discarded window), which would otherwise
    /// land in a row whose frames they don't describe.
    private func rolledWindow(_ metrics: FrameMetrics?, _ instrumentation: Instrumentation) async -> FrameMetrics {
        guard var metrics else {
            _ = await pool.drainHoldAges()
            return FrameMetrics(startNanoseconds: instrumentation.now())
        }
        let now = instrumentation.now()
        guard metrics.elapsedNanoseconds(now: now) >= instrumentation.windowNanoseconds else { return metrics }
        let leaseHold = await pool.drainHoldAges()
        let poolSlots = await pool.slotOccupancy()
        instrumentation.sink.record(metrics.summarize(now: now, leaseHold: leaseHold, poolSlots: poolSlots))
        metrics.startWindow(at: now)
        return metrics
    }
}

extension SimFramePump {
    /// The next copy's deadline, one interval after the previous deadline while
    /// the pump is keeping its cadence, so a sleep that wakes late doesn't
    /// stretch every period by its lateness. An update taken at least half an
    /// interval past its deadline (the pump was idle, or a wake ran very late)
    /// restarts the cadence from `now`.
    static func nextDeadline(
        after previous: ContinuousClock.Instant?,
        now: ContinuousClock.Instant,
        interval: Duration
    ) -> ContinuousClock.Instant {
        if let previous, now < previous.advanced(by: interval / 2) {
            return previous.advanced(by: interval)
        }
        return now.advanced(by: interval)
    }

    /// `deadline`, pushed out to half an interval after the surface resolved
    /// when the resolve itself ran long. The deadline is set before the
    /// resolve, so a resolve slower than an interval would otherwise leave it
    /// expired and let the next update's copy follow this one immediately. A
    /// normal resolve finishes well inside the interval and changes nothing.
    static func deadline(
        _ deadline: ContinuousClock.Instant,
        afterResolvingAt resolvedAt: ContinuousClock.Instant,
        interval: Duration
    ) -> ContinuousClock.Instant {
        max(deadline, resolvedAt.advanced(by: interval / 2))
    }
}

private extension SimFramePump {
    /// Copy `source` into the slot, with a GPU blit when `blitter` can do it,
    /// else on `queue`. Reports the bytes moved and, when `measuring`, CPU
    /// time for comparison with wall time: for a blit, preparing, encoding,
    /// and committing it; for a CPU copy, the copying thread's time, read on
    /// `queue`'s thread, plus any blit attempt that failed first. Without
    /// measurement, CPU time is zero.
    static func timedCopy(
        from source: RetainedSurface,
        to published: PublishedSurface,
        on queue: BlockingWorkQueue,
        blitter: SurfaceBlitter?,
        measuring: Bool
    ) async -> (bytes: Int, cpuNanoseconds: UInt64) {
        var attemptNanoseconds: UInt64 = 0
        if let blitter {
            let attempt = await blitter.blit(from: source, to: published.surface)
            if let bytes = attempt.bytes { return (bytes, measuring ? attempt.cpuNanoseconds : 0) }
            attemptNanoseconds = attempt.cpuNanoseconds
        }
        let failedAttemptNanoseconds = attemptNanoseconds
        return await queue.run {
            let start = measuring ? clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) : 0
            let bytes = published.surface.withRef { destination in
                source.withRef { origin in
                    SurfaceCopy.copy(from: origin, to: destination)
                }
            }
            guard measuring else { return (bytes, 0) }
            return (bytes, failedAttemptNanoseconds &+ (clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- start))
        }
    }

    static func nanoseconds(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        return UInt64(max(0, seconds * 1_000_000_000 + attoseconds / 1_000_000_000))
    }
}
