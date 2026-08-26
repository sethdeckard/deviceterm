// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import SurfaceTrace

/// Daemon-side surface tracing: the per-frame stamp the published surface
/// carries, plus the producer sink resolved from the environment.
///
/// The pure pixel stamp/scan, row schema, and JSONL sink live in the shared
/// `SurfaceTrace` module so the GUI consumer runs the same tested code.
extension SurfaceTraceSink {
    /// Process-wide producer sink, resolved once from the environment. Nil
    /// (tracing off) unless `DEVICETERM_SURFACE_TRACE` names a base path;
    /// when unset, call sites do a runtime nil check and nothing else.
    static let daemonProducer: SurfaceTraceSink? = make(
        baseDirectory: ProcessInfo.processInfo.environment[DeviceTermEnv.surfaceTrace],
        role: "producer"
    )
}
