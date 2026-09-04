// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The single wrapper a backend publishes for one
/// frame, carried through `PaneCoordinator` and `PaneSubscriptionRegistry`.
///
/// It explicitly retains its `LeasedSurface` (the daemon-current owner):
/// `Record.currentSurface` holds a `PublishedSurface`, so assigning a newer
/// one drops the prior `owned` by ARC and releases its `.daemonCurrent`
/// hold. A pooled frame carries `lease` metadata (epoch + generation + the
/// hold-reservation entry point). `lease` is nil only for a frame published
/// without a pool behind it, whose `owned` has no release sink.
struct PublishedSurface: Sendable {
    /// Retains the slot's `LeasedSurface`; its `deinit` releases the
    /// `.daemonCurrent` hold. Never dropped before this value is.
    let owned: LeasedSurface
    /// Per-frame lease overlay. Nil for a frame published without a pool
    /// behind it.
    let lease: LeaseMetadata?
    /// Off-by-default instrumentation stamp assigned at the producer copy
    /// site; nil unless surface tracing is enabled.
    var trace: SurfaceTraceStamp?

    var surface: RetainedSurface { owned.surface }

    init(owned: LeasedSurface, lease: LeaseMetadata? = nil, trace: SurfaceTraceStamp? = nil) {
        self.owned = owned
        self.lease = lease
        self.trace = trace
    }
}
