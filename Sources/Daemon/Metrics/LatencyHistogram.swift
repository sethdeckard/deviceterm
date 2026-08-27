// SPDX-License-Identifier: GPL-3.0-or-later

/// A fixed-bucket distribution of nanosecond durations, so a caller can report
/// p50/p95/max instead of an average that hides the tail.
///
/// Memory is constant and independent of the sample count: recording is a
/// bit-count, a shift, and an increment, with no per-sample storage and no
/// allocation, which is what lets the frame path record every frame without
/// per-frame logging.
///
/// Buckets are four sub-buckets per power of two, so any reported quantile is
/// within 25% of the true value. Values below eight get their own exact bucket,
/// and the octaves span the whole `UInt64` range so nothing saturates. That
/// range is what keeps the 25%: a bounded top bucket would resolve every
/// quantile landing in it to the histogram's overall maximum, reporting a long
/// tail's p50 as its p100.
///
/// A quantile reports its bucket's inclusive upper bound, so it reads as "at
/// most this long" rather than a point estimate.
struct LatencyHistogram: Sendable, Equatable {
    /// Sub-buckets per power of two, as a shift.
    private static let subBits = 2
    private static let subCount = 1 << subBits
    /// Values below this are counted exactly, one bucket each. Above it the
    /// sub-bucket arithmetic has enough mantissa bits to be meaningful.
    private static let linearLimit = UInt64(subCount * 2)
    private static let bucketCount = 64 * subCount

    private(set) var sampleCount: UInt64 = 0
    private(set) var sum: UInt64 = 0
    private(set) var maximum: UInt64 = 0
    private var buckets = [UInt64](repeating: 0, count: bucketCount)

    var mean: UInt64 { sampleCount == 0 ? 0 : sum / sampleCount }
    var p50: UInt64 { quantile(0.5) }
    var p95: UInt64 { quantile(0.95) }

    init() {}

    /// The bucket a duration falls in. Below `linearLimit` the value indexes
    /// itself; above it the index is the power of two plus the top `subBits`
    /// mantissa bits, which keeps the buckets contiguous across the boundary.
    private static func bucketIndex(for value: UInt64) -> Int {
        if value < linearLimit { return Int(value) }
        let octave = 63 - value.leadingZeroBitCount
        let sub = Int((value >> UInt64(octave - subBits)) & UInt64(subCount - 1))
        return min((octave - subBits) * subCount + subCount + sub, bucketCount - 1)
    }

    /// The inclusive upper bound of a bucket, the inverse of `bucketIndex`.
    private static func bucketUpperBound(_ index: Int) -> UInt64 {
        if index < Int(linearLimit) { return UInt64(index) }
        let offset = index - subCount
        let octave = offset / subCount + subBits
        let sub = offset % subCount
        let base = UInt64(subCount + sub + 1)
        let shift = octave - subBits
        // Only the topmost octave's bound exceeds `UInt64`, and no duration in
        // nanoseconds reaches it (2^63 ns is close to three centuries). The
        // caller's clamp to `maximum` is the right answer for a value that did.
        guard shift <= base.leadingZeroBitCount else { return UInt64.max }
        return (base << UInt64(shift)) - 1
    }

    mutating func record(_ nanoseconds: UInt64) {
        buckets[Self.bucketIndex(for: nanoseconds)] += 1
        sampleCount += 1
        sum &+= nanoseconds
        maximum = max(maximum, nanoseconds)
    }

    /// The smallest bucket bound at or above `fraction` of the samples, clamped
    /// to the observed maximum. Zero when nothing has been recorded.
    func quantile(_ fraction: Double) -> UInt64 {
        guard sampleCount > 0 else { return 0 }
        let requested = (Double(sampleCount) * fraction).rounded(.up)
        let rank = max(1, min(UInt64(requested), sampleCount))
        var cumulative: UInt64 = 0
        for (index, bucket) in buckets.enumerated() where bucket > 0 {
            cumulative += bucket
            if cumulative >= rank { return min(Self.bucketUpperBound(index), maximum) }
        }
        return maximum
    }

    mutating func reset() {
        sampleCount = 0
        sum = 0
        maximum = 0
        for index in buckets.indices { buckets[index] = 0 }
    }
}
