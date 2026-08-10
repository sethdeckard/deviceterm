// SPDX-License-Identifier: GPL-3.0-or-later
//
// SurfaceTrace: first-party, off-by-default instrumentation shared by the
// daemon (producer) and the GUI (consumer). Keeping the pure pixel
// stamp/scan, the row schema, and the JSONL sink in one module means both
// sides run the same tested code instead of duplicating it.
//
// The producer stamps a frame's identity (the pool generation) into the
// surface pixels; after the command buffer completes, the consumer scans it
// back. The consumer already knows the identity it intended to render (the
// wire sequence), so it records that expected id, the observed id, and the
// count of internally-inconsistent rows for offline comparison,
// characterizing the reuse race without observing the bytes the GPU
// actually sampled.

import Foundation
import IOSurface

/// Writes a 32-bit id into column 0 of every row and scans it back.
public enum SurfacePixelStamp {
    /// Stamp the low 32 bits of `identifier` into the first pixel of every
    /// row. Locks for write.
    public static func stamp(_ identifier: UInt64, into surface: IOSurfaceRef) {
        let value = UInt32(truncatingIfNeeded: identifier)
        IOSurfaceLock(surface, [], nil)
        defer { IOSurfaceUnlock(surface, [], nil) }
        let base = IOSurfaceGetBaseAddress(surface)
        let stride = IOSurfaceGetBytesPerRow(surface)
        let rows = IOSurfaceGetHeight(surface)
        for row in 0..<rows {
            base.advanced(by: row * stride).assumingMemoryBound(to: UInt32.self).pointee = value
        }
    }

    /// Read column 0 back. `reference` is row 0's stamp (the observed id);
    /// `mismatchRows` is the number of later rows that differ from it, a
    /// partial-mutation count independent of any expected id.
    public static func scan(_ surface: IOSurfaceRef) -> (reference: UInt32, mismatchRows: Int) {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface)
        let stride = IOSurfaceGetBytesPerRow(surface)
        let rows = IOSurfaceGetHeight(surface)
        guard rows > 0 else { return (0, 0) }
        let reference = base.assumingMemoryBound(to: UInt32.self).pointee
        var mismatches = 0
        for row in 1..<rows {
            let value = base.advanced(by: row * stride).assumingMemoryBound(to: UInt32.self).pointee
            if value != reference { mismatches += 1 }
        }
        return (reference, mismatches)
    }
}

/// One JSONL row joined offline by `(paneId, traceId)`. The producer sets
/// `traceId` to the generation it stamped; the consumer sets `traceId` to
/// the id it intended to render (the wire sequence) and reports what it
/// `observedTraceId` scanned back plus the `mismatchRows` count.
///
/// `traceId` is the full 64-bit generation, so the producer/consumer join
/// on it is exact. Only `observedTraceId` is truncated to the 32-bit pixel-
/// stamp width, so a swap check compares it against the low 32 bits of
/// `traceId`.
public struct SurfaceTraceRow: Codable, Sendable, Equatable {
    public let role: String
    public let paneId: String
    public let traceId: UInt64
    public var observedTraceId: UInt64?
    public let monotonicNanoseconds: UInt64
    public var mismatchRows: Int?

    public init(
        role: String,
        paneId: String,
        traceId: UInt64,
        monotonicNanoseconds: UInt64,
        observedTraceId: UInt64? = nil,
        mismatchRows: Int? = nil
    ) {
        self.role = role
        self.paneId = paneId
        self.traceId = traceId
        self.observedTraceId = observedTraceId
        self.monotonicNanoseconds = monotonicNanoseconds
        self.mismatchRows = mismatchRows
    }
}

/// Append-only JSONL sink. `@unchecked Sendable` is sound because the only
/// mutable state (the file handle and encoder) is touched exclusively on
/// the private serial `queue`.
public final class SurfaceTraceSink: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "deviceterm.surface-trace")
    private let encoder = JSONEncoder()

    /// Open `path` for appending; nil if it can't be created/opened.
    public init?(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: expanded) {
            FileManager.default.createFile(atPath: expanded, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: expanded) else { return nil }
        handle.seekToEndOfFile()
        self.handle = handle
    }

    /// Build a role-suffixed sink when `baseDirectory` is a non-empty base
    /// path; nil (tracing off) otherwise. Producer and consumer pass
    /// different roles so two processes never contend on one file.
    public static func make(baseDirectory: String?, role: String) -> SurfaceTraceSink? {
        guard let base = baseDirectory, !base.isEmpty else { return nil }
        return SurfaceTraceSink(path: "\(base).\(role).jsonl")
    }

    public func record(_ row: SurfaceTraceRow) {
        queue.async { [handle, encoder] in
            guard var data = try? encoder.encode(row) else { return }
            data.append(0x0A)
            try? handle.write(contentsOf: data)
        }
    }

    /// Flush pending writes (tests read the file right after recording).
    public func drain() {
        queue.sync {}
    }
}
