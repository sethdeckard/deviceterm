// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One window of device-frame measurements, emitted as a single JSONL row and
/// a single log line.
///
/// Everything here is an aggregate over the window rather than a per-frame
/// record. A later frame closes the window once at least one second has
/// elapsed, keeping output far below per-frame volume.
///
/// The row includes geometry, pixel format, and window duration so its rates
/// can be interpreted, because a frame rate means nothing without the frame
/// size that produced it. Identifying the run itself (device, OS, workload,
/// thermal state) is the capture procedure's job, not the row's.
struct DeviceFrameMetricsSummary: Codable, Sendable, Equatable {
    /// One duration distribution. Quantiles are bucket upper bounds, so read
    /// them as "at most", and `sampleCount` can differ between series in the same
    /// window because not every frame reaches every stage.
    struct Series: Codable, Sendable, Equatable {
        let sampleCount: UInt64
        let meanNanoseconds: UInt64
        let p50Nanoseconds: UInt64
        let p95Nanoseconds: UInt64
        let maxNanoseconds: UInt64
    }

    let windowNanoseconds: UInt64
    let sourceWidth: Int
    let sourceHeight: Int
    let contentWidth: Int
    let contentHeight: Int
    /// The decoder's output format as its four-character code, e.g. `BGRA`.
    let pixelFormat: String
    /// Frames taken off the decoder's stream this window.
    let framesConsumed: Int
    /// Frames that reached the pane. The shortfall against `framesConsumed` is
    /// the two drop counts below.
    let framesPublished: Int
    let framesDroppedNoSurface: Int
    let framesDroppedExhaustion: Int
    /// Bytes the copies actually moved this window, as reported by the copy
    /// itself. An uncropped copy spans the whole row stride, so this exceeds
    /// the visible pixels by whatever alignment padding the surface carries.
    let bytesMoved: Int
    /// How many times the geometry above changed within this window. Above
    /// zero means the row mixes geometries: the fields describe the last frame
    /// while the counts and timings span all of them, so discard it rather
    /// than reading a per-frame figure off it.
    let geometryChanges: Int
    let copy: Series
    /// Time a published surface stayed leased to the GUI, measured from grant
    /// to the release watermark that freed it. Bounded by the surface pool: it
    /// reuses the hold timestamps the pool already keeps per slot.
    let leaseHold: Series

    var framesPerSecond: Double {
        windowNanoseconds == 0 ? 0 : Double(framesPublished) * 1_000_000_000 / Double(windowNanoseconds)
    }

    /// Derived from the summed bytes rather than a frame count times a
    /// representative frame, so a window whose geometry shifted still reports
    /// what the copies moved.
    var bytesPerSecond: Double {
        windowNanoseconds == 0 ? 0 : Double(bytesMoved) * 1_000_000_000 / Double(windowNanoseconds)
    }

    /// The human-readable per-window form. Fixed field order so successive lines
    /// diff cleanly between a baseline and a comparison run.
    var logLine: String {
        let megabytesPerSecond = bytesPerSecond / 1_000_000
        // The marker rides next to the geometry it qualifies, so a row that
        // mixes geometries can't be read as describing one.
        let mixed = geometryChanges > 0 ? " (mixed x\(geometryChanges))" : ""
        return "frame-metrics: \(sourceWidth)x\(sourceHeight)→\(contentWidth)x\(contentHeight)"
            + " \(pixelFormat)\(mixed)"
            + " · consumed=\(framesConsumed) published=\(framesPublished)"
            + " dropped=\(framesDroppedNoSurface)/\(framesDroppedExhaustion)"
            + " · \(Self.rounded(framesPerSecond))fps \(Self.rounded(megabytesPerSecond))MB/s"
            + " · copy p50=\(Self.microseconds(copy.p50Nanoseconds))"
            + " p95=\(Self.microseconds(copy.p95Nanoseconds))"
            + " max=\(Self.microseconds(copy.maxNanoseconds))"
            + " · lease p50=\(Self.microseconds(leaseHold.p50Nanoseconds))"
            + " p95=\(Self.microseconds(leaseHold.p95Nanoseconds))"
            + " max=\(Self.microseconds(leaseHold.maxNanoseconds))"
    }

    private static func rounded(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func microseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.1fus", Double(nanoseconds) / 1_000)
    }
}
