// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
import Foundation
import IOSurface
@testable import SurfaceTrace
import Testing

// Hermetic tests for the shared surface-trace detector and sink. The GPU
// completion path that drives them (the Metal renderer) is off-by-default
// instrumentation and requires manual GUI verification.

private func makeSurface(width: Int, height: Int) -> IOSurfaceRef? {
    let bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4)
    let properties: [IOSurfacePropertyKey: Any] = [
        .width: width,
        .height: height,
        .bytesPerElement: 4,
        .bytesPerRow: bytesPerRow,
        .pixelFormat: kCVPixelFormatType_32BGRA
    ]
    return IOSurfaceCreate(properties as CFDictionary)
}

/// Overwrite column 0 of `rows` with `value`, simulating a partial
/// producer overwrite of a surface a consumer is still reading.
private func overwriteColumnZero(_ value: UInt32, rows: Range<Int>, in surface: IOSurfaceRef) {
    IOSurfaceLock(surface, [], nil)
    defer { IOSurfaceUnlock(surface, [], nil) }
    let base = IOSurfaceGetBaseAddress(surface)
    let stride = IOSurfaceGetBytesPerRow(surface)
    for row in rows {
        base.advanced(by: row * stride).assumingMemoryBound(to: UInt32.self).pointee = value
    }
}

@Test("pixel stamp round-trips a trace id")
func pixelStampRoundTrips() throws {
    let surface = try #require(makeSurface(width: 8, height: 16))
    SurfacePixelStamp.stamp(0xDEAD_BEEF_1234_5678, into: surface)
    let scanned = SurfacePixelStamp.scan(surface)
    // The low 32 bits are stamped into each row.
    #expect(scanned.reference == 0x1234_5678)
    #expect(scanned.mismatchRows == 0)
}

@Test("pixel scan counts rows a partial mutation changed")
func pixelScanCountsPartialMutation() throws {
    let surface = try #require(makeSurface(width: 8, height: 16))
    SurfacePixelStamp.stamp(0x0000_0011, into: surface)
    // A later frame overwrites rows 10...15 (6 rows) before the consumer
    // finished reading; the reference row 0 is untouched.
    overwriteColumnZero(0x0000_0022, rows: 10..<16, in: surface)
    let scanned = SurfacePixelStamp.scan(surface)
    #expect(scanned.reference == 0x0000_0011)
    #expect(scanned.mismatchRows == 6)
}

@Test("sink is nil without a base path and writes JSONL with one")
func sinkGatingAndOutput() throws {
    // Off by default.
    #expect(SurfaceTraceSink.make(baseDirectory: nil, role: "producer") == nil)
    #expect(SurfaceTraceSink.make(baseDirectory: "", role: "producer") == nil)

    // On when a base path is provided.
    let base = NSTemporaryDirectory() + "surface-trace-\(UUID().uuidString)"
    let sink = try #require(SurfaceTraceSink.make(baseDirectory: base, role: "consumer"))
    let row = SurfaceTraceRow(
        role: "consumer",
        paneId: "pane-1",
        traceId: 7,
        monotonicNanoseconds: 123,
        observedTraceId: 9,
        mismatchRows: 4
    )
    sink.record(row)
    sink.drain()

    let url = URL(fileURLWithPath: "\(base).consumer.jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let contents = try String(contentsOf: url, encoding: .utf8)
    let line = try #require(contents.split(separator: "\n").first)
    let decoded = try JSONDecoder().decode(SurfaceTraceRow.self, from: Data(line.utf8))
    #expect(decoded == row)
}
