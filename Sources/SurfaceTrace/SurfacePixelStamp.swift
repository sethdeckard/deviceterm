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
