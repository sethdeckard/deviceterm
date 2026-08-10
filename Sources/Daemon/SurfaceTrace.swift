// SPDX-License-Identifier: GPL-3.0-or-later
//
// Daemon-side surface tracing: the per-frame stamp the published surface
// carries, plus the producer sink resolved from the environment. The pure
// pixel stamp/scan, row schema, and JSONL sink live in the shared
// `SurfaceTrace` module so the GUI consumer runs the same tested code.

import DaemonProtocol
import Foundation
import SurfaceTrace

/// Producer-assigned join key for one published device frame. `traceId` is
/// the pool generation (which the wire `sequence` also carries), stamped
/// into the pixels so the GUI can compare what it intended to render
/// against what it scanned back.
struct SurfaceTraceStamp: Sendable, Equatable {
    let traceId: UInt64
    let producedAtNanoseconds: UInt64
}

extension SurfaceTraceSink {
    /// Process-wide producer sink, resolved once from the environment. Nil
    /// (tracing off) unless `DEVICETERM_SURFACE_TRACE` names a base path;
    /// when unset, call sites do a runtime nil check and nothing else.
    static let daemonProducer: SurfaceTraceSink? = make(
        baseDirectory: ProcessInfo.processInfo.environment[DeviceTermEnv.surfaceTrace],
        role: "producer"
    )
}
