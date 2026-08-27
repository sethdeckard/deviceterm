// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
@testable import Daemon
import Foundation
import Testing

private func sampleSummary() -> DeviceFrameMetricsSummary {
    var metrics = DeviceFrameMetrics(startNanoseconds: 0)
    metrics.noteGeometry(
        sourceWidth: 8,
        sourceHeight: 8,
        contentWidth: 8,
        contentHeight: 8,
        pixelFormat: kCVPixelFormatType_32BGRA
    )
    metrics.noteConsumed()
    metrics.noteCopy(nanoseconds: 1_234, bytes: 256)
    metrics.notePublished()
    return metrics.summarize(now: 1_000_000_000, leaseHold: LatencyHistogram())
}

private func temporaryBase() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("frame-metrics-\(UUID().uuidString)").path
}

@Test("no environment value means metrics are off, which is how the frame path skips its clocks")
func makeReturnsNilWithoutABasePath() {
    #expect(FrameMetricsSink.make(baseDirectory: nil, deviceId: "device", log: nil) == nil)
    #expect(FrameMetricsSink.make(baseDirectory: "", deviceId: "device", log: nil) == nil)
}

@Test
func recordAppendsOneJSONLineAndLogsIt() throws {
    let base = temporaryBase()
    let logged = LoggedLines()
    // Bound before the macro: `#require` re-expands a call it wraps, and the
    // expansion drops the `@Sendable` the `log` parameter requires.
    let made = FrameMetricsSink.make(baseDirectory: base, deviceId: "abc", log: { logged.append($0) })
    let sink = try #require(made)
    let summary = sampleSummary()
    sink.record(summary)
    sink.record(summary)
    sink.drain()

    let path = "\(base).abc.frames.jsonl"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let contents = try String(contentsOfFile: path, encoding: .utf8)
    let rows = contents.split(separator: "\n")
    #expect(rows.count == 2)
    let decoded = try JSONDecoder().decode(DeviceFrameMetricsSummary.self, from: Data(rows[0].utf8))
    #expect(decoded == summary)
    #expect(logged.lines == [summary.logLine, summary.logLine])
}

@Test("each device gets its own file, so two mirrored devices can't interleave rows")
func devicesDoNotShareAFile() throws {
    let base = temporaryBase()
    let first = try #require(FrameMetricsSink.make(baseDirectory: base, deviceId: "first", log: nil))
    let second = try #require(FrameMetricsSink.make(baseDirectory: base, deviceId: "second", log: nil))
    first.record(sampleSummary())
    second.record(sampleSummary())
    second.record(sampleSummary())
    first.drain()
    second.drain()

    let firstPath = "\(base).first.frames.jsonl"
    let secondPath = "\(base).second.frames.jsonl"
    defer {
        try? FileManager.default.removeItem(atPath: firstPath)
        try? FileManager.default.removeItem(atPath: secondPath)
    }
    #expect(try String(contentsOfFile: firstPath, encoding: .utf8).split(separator: "\n").count == 1)
    #expect(try String(contentsOfFile: secondPath, encoding: .utf8).split(separator: "\n").count == 2)
}

@Test("an unopenable path loses the file, not the run, and says so")
func recordStillLogsWhenTheFileCannotBeOpened() {
    let logged = LoggedLines()
    let sink = FrameMetricsSink(path: "/nonexistent-directory/frames.jsonl", log: { logged.append($0) })
    sink.record(sampleSummary())
    sink.drain()
    // The open failure is reported, then the summary line still arrives: a lost
    // file must not look like a healthy capture.
    #expect(logged.lines.count == 2)
    #expect(logged.lines[0].contains("can't open"))
    #expect(logged.lines[1] == sampleSummary().logLine)
}

/// Collects the sink's log lines. The sink's `log` is `@Sendable`, so the
/// collector needs its own lock rather than relying on the caller's isolation.
private final class LoggedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(line)
    }
}
