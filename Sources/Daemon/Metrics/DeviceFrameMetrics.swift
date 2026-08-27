// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
import Foundation

/// Accumulates one window of device-frame measurements for the frame task.
///
/// A plain value confined to the backend's single serial frame task: it is
/// mutated only there, summarized once per window, and reset in place, so there
/// is no shared state and no synchronization. The measurements do not
/// influence pipeline behavior.
///
/// Bytes and dimensions are recorded from the surfaces actually handled rather
/// than derived from an assumed pixel size, so the row stays honest if the
/// decoder's output format ever changes.
struct DeviceFrameMetrics: Sendable {
    private var windowStartNanoseconds: UInt64
    private var framesConsumed = 0
    private var framesPublished = 0
    private var framesDroppedNoSurface = 0
    private var framesDroppedExhaustion = 0
    private var sourceWidth = 0
    private var sourceHeight = 0
    private var contentWidth = 0
    private var contentHeight = 0
    private var pixelFormat: OSType = 0
    private var bytesMoved = 0
    private var geometryChanges = 0
    /// Whether this window has seen geometry yet. The fields above persist
    /// across a rollover so an idle window still says what the stream is, which
    /// means they cannot answer "did the geometry change *within this row*".
    private var windowHasGeometry = false
    private var copy = LatencyHistogram()

    init(startNanoseconds: UInt64) {
        windowStartNanoseconds = startNanoseconds
    }

    /// A four-character code as text, e.g. `BGRA`. Falls back to the decimal
    /// value when any byte is unprintable, so an unexpected format is still
    /// identifiable in the row.
    private static func fourCharacterCode(_ value: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(value) }
        return String(bytes: bytes, encoding: .utf8) ?? String(value)
    }

    mutating func noteConsumed() {
        framesConsumed += 1
    }

    mutating func noteDroppedNoSurface() {
        framesDroppedNoSurface += 1
    }

    mutating func noteDroppedExhaustion() {
        framesDroppedExhaustion += 1
    }

    /// Geometry is the stream's, not the window's, so the fields are the last
    /// values seen. A rotation or a content rect locking mid-window would leave
    /// the row describing frames it did not all apply to, so the change is
    /// counted: a row with `geometryChanges` above zero mixes geometries and
    /// its per-frame figures should not be trusted.
    mutating func noteGeometry(
        sourceWidth: Int,
        sourceHeight: Int,
        contentWidth: Int,
        contentHeight: Int,
        pixelFormat: OSType
    ) {
        let changed = sourceWidth != self.sourceWidth
            || sourceHeight != self.sourceHeight
            || contentWidth != self.contentWidth
            || contentHeight != self.contentHeight
            || pixelFormat != self.pixelFormat
        // Only a change this window witnessed counts. A rotation landing on the
        // first frame after a rollover differs from the retained geometry but
        // applies to every frame the new row counts, so marking it mixed would
        // discard a row that describes exactly one geometry.
        if changed, windowHasGeometry { geometryChanges += 1 }
        windowHasGeometry = true
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.contentWidth = contentWidth
        self.contentHeight = contentHeight
        self.pixelFormat = pixelFormat
    }

    /// `bytes` accumulates rather than replacing, so the window's throughput is
    /// the sum of what the copies actually moved. Multiplying a frame count by
    /// one representative frame's size would misreport any window whose
    /// geometry shifted partway through.
    mutating func noteCopy(nanoseconds: UInt64, bytes: Int) {
        copy.record(nanoseconds)
        bytesMoved += bytes
    }

    mutating func notePublished() {
        framesPublished += 1
    }

    func elapsedNanoseconds(now: UInt64) -> UInt64 {
        now &- windowStartNanoseconds
    }

    /// Close the window. `leaseHold` comes from the surface pool, which owns
    /// those timings because it owns the hold timestamps.
    func summarize(now: UInt64, leaseHold: LatencyHistogram) -> DeviceFrameMetricsSummary {
        DeviceFrameMetricsSummary(
            windowNanoseconds: elapsedNanoseconds(now: now),
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            contentWidth: contentWidth,
            contentHeight: contentHeight,
            pixelFormat: Self.fourCharacterCode(pixelFormat),
            framesConsumed: framesConsumed,
            framesPublished: framesPublished,
            framesDroppedNoSurface: framesDroppedNoSurface,
            framesDroppedExhaustion: framesDroppedExhaustion,
            bytesMoved: bytesMoved,
            geometryChanges: geometryChanges,
            copy: Self.series(copy),
            leaseHold: Self.series(leaseHold)
        )
    }

    /// Clear the counters and start a new window. Geometry is deliberately kept:
    /// it describes the stream, not the window, and a window with no frames in
    /// it should still say what the stream was.
    mutating func startWindow(at nanoseconds: UInt64) {
        windowStartNanoseconds = nanoseconds
        framesConsumed = 0
        framesPublished = 0
        framesDroppedNoSurface = 0
        framesDroppedExhaustion = 0
        bytesMoved = 0
        geometryChanges = 0
        windowHasGeometry = false
        copy.reset()
    }
}

private extension DeviceFrameMetrics {
    static func series(_ histogram: LatencyHistogram) -> DeviceFrameMetricsSummary.Series {
        DeviceFrameMetricsSummary.Series(
            sampleCount: histogram.sampleCount,
            meanNanoseconds: histogram.mean,
            p50Nanoseconds: histogram.p50,
            p95Nanoseconds: histogram.p95,
            maxNanoseconds: histogram.maximum
        )
    }
}
