// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import SurfaceTrace

/// GUI-side surface tracing: the consumer sink and delay resolved from the
/// environment, and the context the content view hands the renderer.
///
/// The pure pixel scan, row schema, and JSONL sink live in the shared
/// `SurfaceTrace` module so producer and consumer run the same tested code.
///
/// After a device frame's command buffer reaches a terminal state, the
/// consumer scans the surface and records the generation it intended to
/// render (the wire sequence) alongside what it observed and the count of
/// internally-inconsistent rows. An optional adversarial delay lets the
/// daemon reuse the slot first, so the scan characterizes the reuse race.
extension SurfaceTraceSink {
    /// Process-wide consumer sink, resolved once from the environment. Nil
    /// (tracing off) unless `DEVICETERM_SURFACE_TRACE` names a base path;
    /// when unset, call sites do a runtime nil check and nothing else.
    static let guiConsumer: SurfaceTraceSink? = make(
        baseDirectory: ProcessInfo.processInfo.environment[DeviceTermEnv.surfaceTrace],
        role: "consumer"
    )

    /// Adversarial consumer delay injected before the post-completion scan.
    static let consumerDelayNanoseconds: UInt64 = {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment[DeviceTermEnv.surfaceConsumerDelayMs],
            let milliseconds = UInt64(raw) else { return 0 }
        return milliseconds * 1_000_000
    }()
}
