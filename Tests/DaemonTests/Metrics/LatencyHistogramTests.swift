// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Testing

// The histogram keeps bucket counts rather than samples, so these tests pin
// its quantile guarantees: never below the truth, never above the recorded
// maximum, and within the documented 25% resolution.

@Test
func emptyHistogramReportsZeroes() {
    let histogram = LatencyHistogram()
    #expect(histogram.sampleCount == 0)
    #expect(histogram.sum == 0)
    #expect(histogram.maximum == 0)
    #expect(histogram.mean == 0)
    #expect(histogram.p50 == 0)
    #expect(histogram.p95 == 0)
}

@Test("a single sample reports exactly, since every quantile clamps to the maximum", arguments: [
    UInt64(0), 1, 7, 8, 9, 1_000, 1_048_576, 12_345_678
])
func singleSampleReportsExactly(sample: UInt64) {
    var histogram = LatencyHistogram()
    histogram.record(sample)
    #expect(histogram.sampleCount == 1)
    #expect(histogram.sum == sample)
    #expect(histogram.maximum == sample)
    #expect(histogram.mean == sample)
    #expect(histogram.p50 == sample)
    #expect(histogram.p95 == sample)
}

@Test
func smallValuesAreCountedExactly() {
    var histogram = LatencyHistogram()
    // The linear region: each value below eight owns a bucket, so the median of
    // 0...7 is not an estimate.
    for value in UInt64(0)...7 { histogram.record(value) }
    #expect(histogram.sampleCount == 8)
    #expect(histogram.maximum == 7)
    #expect(histogram.p50 == 3)
}

@Test
func quantilesNeverUnderstateAndStayWithinResolution() {
    var histogram = LatencyHistogram()
    for value in UInt64(1)...1_000 { histogram.record(value) }
    // A quantile is its bucket's upper bound, so it is never below the true
    // value, and four sub-buckets per octave cap the overshoot at 25%.
    #expect(histogram.p50 >= 500)
    #expect(histogram.p50 <= 625)
    #expect(histogram.p95 >= 950)
    #expect(histogram.p95 <= 1_000)
    #expect(histogram.maximum == 1_000)
}

@Test
func quantilesAreMonotonicAndBoundedByTheMaximum() {
    var histogram = LatencyHistogram()
    for value in stride(from: UInt64(3), through: 9_000, by: 7) { histogram.record(value) }
    #expect(histogram.p50 <= histogram.p95)
    #expect(histogram.p95 <= histogram.maximum)
}

@Test("a single very long duration still reports itself exactly")
func aSingleVeryLongDurationReportsExactly() {
    var histogram = LatencyHistogram()
    let tenSeconds: UInt64 = 10_000_000_000
    histogram.record(tenSeconds)
    #expect(histogram.maximum == tenSeconds)
    #expect(histogram.p95 == tenSeconds)
}

@Test("a long tail's p50 stays within resolution instead of collapsing to the maximum")
func longDurationsDoNotCollapseToTheMaximum() {
    var histogram = LatencyHistogram()
    let eightSeconds: UInt64 = 8_000_000_000
    let hundredSeconds: UInt64 = 100_000_000_000
    histogram.record(eightSeconds)
    histogram.record(hundredSeconds)
    #expect(histogram.maximum == hundredSeconds)
    // With an unbounded top bucket both samples landed in it and p50 resolved
    // to the maximum, reporting the tail's p50 as its p100.
    #expect(histogram.p50 >= eightSeconds)
    #expect(histogram.p50 <= eightSeconds + eightSeconds / 4)
}

@Test("resolution holds at every magnitude, not just the ones frame timings use", arguments: [
    UInt64(1_000), 1_000_000, 1_000_000_000, 60_000_000_000, 3_600_000_000_000
])
func smallerOfTwoSamplesStaysWithinResolution(sample: UInt64) {
    var histogram = LatencyHistogram()
    histogram.record(sample)
    histogram.record(sample * 1_000)
    #expect(histogram.p50 >= sample)
    #expect(histogram.p50 <= sample + sample / 4)
}

@Test
func resetClearsEveryBucket() {
    var histogram = LatencyHistogram()
    for value in UInt64(1)...100 { histogram.record(value) }
    histogram.reset()
    #expect(histogram == LatencyHistogram())
}
