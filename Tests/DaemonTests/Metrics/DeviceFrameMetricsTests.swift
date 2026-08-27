// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
@testable import Daemon
import Foundation
import Testing

private func populated(startNanoseconds: UInt64 = 0) -> DeviceFrameMetrics {
    var metrics = DeviceFrameMetrics(startNanoseconds: startNanoseconds)
    metrics.noteGeometry(
        sourceWidth: 1_206,
        sourceHeight: 2_624,
        contentWidth: 1_206,
        contentHeight: 2_622,
        pixelFormat: kCVPixelFormatType_32BGRA
    )
    for _ in 0..<60 {
        metrics.noteConsumed()
        metrics.noteCopy(nanoseconds: 3_000_000, bytes: 1_206 * 4 * 2_622)
        metrics.notePublished()
    }
    // A dropped frame was consumed too. Leaving these out would build a row
    // that violates the shortfall the summary documents, and no real window
    // can produce one.
    for _ in 0..<3 { metrics.noteConsumed() }
    metrics.noteDroppedNoSurface()
    metrics.noteDroppedExhaustion()
    metrics.noteDroppedExhaustion()
    return metrics
}

@Test
func summaryCarriesTheWindowsCountsAndGeometry() {
    let summary = populated().summarize(now: 1_000_000_000, leaseHold: LatencyHistogram())
    #expect(summary.windowNanoseconds == 1_000_000_000)
    #expect(summary.sourceWidth == 1_206)
    #expect(summary.sourceHeight == 2_624)
    #expect(summary.contentWidth == 1_206)
    #expect(summary.contentHeight == 2_622)
    #expect(summary.framesConsumed == 63)
    #expect(summary.framesPublished == 60)
    #expect(summary.framesDroppedNoSurface == 1)
    #expect(summary.framesDroppedExhaustion == 2)
    #expect(summary.copy.sampleCount == 60)
    #expect(summary.copy.p50Nanoseconds == 3_000_000)
}

@Test("consumed accounts for every frame: the published ones plus each drop")
func consumedEqualsPublishedPlusDrops() {
    let summary = populated().summarize(now: 1_000_000_000, leaseHold: LatencyHistogram())
    let accounted = summary.framesPublished
        + summary.framesDroppedNoSurface
        + summary.framesDroppedExhaustion
    #expect(summary.framesConsumed == accounted)
}

@Test("the decoder's format is reported as its four-character code")
func pixelFormatRendersAsAFourCharacterCode() {
    let summary = populated().summarize(now: 1_000_000_000, leaseHold: LatencyHistogram())
    #expect(summary.pixelFormat == "BGRA")
}

@Test("a format with unprintable bytes falls back to its numeric value")
func unprintablePixelFormatFallsBackToDigits() {
    var metrics = DeviceFrameMetrics(startNanoseconds: 0)
    metrics.noteGeometry(sourceWidth: 4, sourceHeight: 4, contentWidth: 4, contentHeight: 4, pixelFormat: 1)
    let summary = metrics.summarize(now: 1, leaseHold: LatencyHistogram())
    #expect(summary.pixelFormat == "1")
}

@Test
func ratesDeriveFromTheWindowRatherThanAnAssumedFrameRate() {
    // Half a second of 60 published frames is 120 fps, not 60: the rate has to
    // come from the window it was measured over.
    let summary = populated().summarize(now: 500_000_000, leaseHold: LatencyHistogram())
    #expect(abs(summary.framesPerSecond - 120) < 0.001)
    #expect(abs(summary.bytesPerSecond - Double(summary.bytesMoved) * 2) < 1)
}

@Test("bytes accumulate over the window instead of standing in for every frame")
func bytesAccumulateAcrossTheWindow() {
    let summary = populated().summarize(now: 1_000_000_000, leaseHold: LatencyHistogram())
    #expect(summary.bytesMoved == 60 * 1_206 * 4 * 2_622)
}

@Test("the first geometry of a run is not a change")
func firstGeometryIsNotCountedAsAChange() {
    let summary = populated().summarize(now: 1_000_000_000, leaseHold: LatencyHistogram())
    #expect(summary.geometryChanges == 0)
}

@Test("a rotation mid-window marks the row rather than silently relabelling it")
func geometryChangeWithinAWindowIsCounted() {
    var metrics = populated()
    metrics.noteGeometry(
        sourceWidth: 2_624,
        sourceHeight: 1_206,
        contentWidth: 2_622,
        contentHeight: 1_206,
        pixelFormat: kCVPixelFormatType_32BGRA
    )
    metrics.noteConsumed()
    metrics.noteCopy(nanoseconds: 3_000_000, bytes: 2_622 * 4 * 1_206)
    metrics.notePublished()
    let summary = metrics.summarize(now: 1_000_000_000, leaseHold: LatencyHistogram())
    #expect(summary.geometryChanges == 1)
    // The row reports the newest geometry while its counts span both, which is
    // exactly why the marker has to be there.
    #expect(summary.sourceWidth == 2_624)
    #expect(summary.framesPublished == 61)
    #expect(summary.logLine.contains("(mixed x1)"))
}

@Test("a rotation landing on the first frame after a rollover is not a mixed row")
func geometryChangingAtAWindowBoundaryIsNotCountedAsMixed() {
    var metrics = populated()
    metrics.startWindow(at: 5_000_000_000)
    // Every frame this window counts uses the new geometry, so the row
    // describes exactly one and must not be discarded as mixed.
    metrics.noteGeometry(
        sourceWidth: 2_624,
        sourceHeight: 1_206,
        contentWidth: 2_622,
        contentHeight: 1_206,
        pixelFormat: kCVPixelFormatType_32BGRA
    )
    metrics.noteConsumed()
    metrics.noteCopy(nanoseconds: 3_000_000, bytes: 2_622 * 4 * 1_206)
    metrics.notePublished()
    let summary = metrics.summarize(now: 6_000_000_000, leaseHold: LatencyHistogram())
    #expect(summary.geometryChanges == 0)
    #expect(summary.sourceWidth == 2_624)
    #expect(!summary.logLine.contains("mixed"))
}

@Test("re-noting the same geometry is not a change")
func repeatedGeometryIsNotAChange() {
    var metrics = populated()
    metrics.noteGeometry(
        sourceWidth: 1_206,
        sourceHeight: 2_624,
        contentWidth: 1_206,
        contentHeight: 2_622,
        pixelFormat: kCVPixelFormatType_32BGRA
    )
    #expect(metrics.summarize(now: 1_000_000_000, leaseHold: LatencyHistogram()).geometryChanges == 0)
}

@Test("a new window clears the mixed marker and the byte total")
func startWindowClearsBytesAndGeometryChanges() {
    var metrics = populated()
    metrics.noteGeometry(
        sourceWidth: 2_624,
        sourceHeight: 1_206,
        contentWidth: 2_622,
        contentHeight: 1_206,
        pixelFormat: kCVPixelFormatType_32BGRA
    )
    metrics.startWindow(at: 5_000_000_000)
    let summary = metrics.summarize(now: 6_000_000_000, leaseHold: LatencyHistogram())
    #expect(summary.geometryChanges == 0)
    #expect(summary.bytesMoved == 0)
    #expect(summary.bytesPerSecond == 0)
}

@Test
func anEmptyWindowReportsZeroRatesRatherThanDividingByZero() {
    let metrics = DeviceFrameMetrics(startNanoseconds: 500)
    let summary = metrics.summarize(now: 500, leaseHold: LatencyHistogram())
    #expect(summary.windowNanoseconds == 0)
    #expect(summary.framesPerSecond == 0)
    #expect(summary.bytesPerSecond == 0)
}

@Test("a new window clears the counts but keeps the geometry describing the stream")
func startWindowClearsCountsAndKeepsGeometry() {
    var metrics = populated()
    metrics.startWindow(at: 5_000_000_000)
    let summary = metrics.summarize(now: 6_000_000_000, leaseHold: LatencyHistogram())
    #expect(summary.windowNanoseconds == 1_000_000_000)
    #expect(summary.framesConsumed == 0)
    #expect(summary.framesPublished == 0)
    #expect(summary.framesDroppedNoSurface == 0)
    #expect(summary.framesDroppedExhaustion == 0)
    #expect(summary.copy.sampleCount == 0)
    #expect(summary.contentWidth == 1_206)
    #expect(summary.pixelFormat == "BGRA")
}

@Test
func leaseHoldSeriesComesFromTheCallersPool() {
    var holds = LatencyHistogram()
    holds.record(8_000_000)
    let summary = populated().summarize(now: 1_000_000_000, leaseHold: holds)
    #expect(summary.leaseHold.sampleCount == 1)
    #expect(summary.leaseHold.maxNanoseconds == 8_000_000)
}

@Test
func theSummaryRoundTripsThroughJSON() throws {
    let summary = populated().summarize(now: 1_000_000_000, leaseHold: LatencyHistogram())
    let data = try JSONEncoder().encode(summary)
    let decoded = try JSONDecoder().decode(DeviceFrameMetricsSummary.self, from: data)
    #expect(decoded == summary)
}

@Test("the log line names the geometry, the counts, and both duration series")
func logLineCarriesTheFieldsAComparisonNeeds() {
    var holds = LatencyHistogram()
    holds.record(8_000_000)
    let line = populated().summarize(now: 1_000_000_000, leaseHold: holds).logLine
    #expect(line.contains("1206x2624→1206x2622"))
    #expect(line.contains("BGRA"))
    #expect(line.contains("consumed=63"))
    #expect(line.contains("published=60"))
    #expect(line.contains("dropped=1/2"))
    #expect(line.contains("copy p50="))
    #expect(line.contains("lease p50="))
}
