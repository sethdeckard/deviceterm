// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

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
