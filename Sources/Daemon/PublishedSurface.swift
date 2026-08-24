// SPDX-License-Identifier: GPL-3.0-or-later
//
// PublishedSurface: the single wrapper a backend publishes for one
// frame, carried through `PaneCoordinator` and `PaneSubscriptionRegistry`.
//
// It explicitly retains its `LeasedSurface` (the daemon-current owner):
// `Record.currentSurface` holds a `PublishedSurface`, so assigning a newer
// one drops the prior `owned` by ARC and releases its `.daemonCurrent`
// hold. A device frame carries `lease` metadata (epoch + generation +
// the hold-reservation entry point); a simulator frame sets `lease` to nil
// and an `owned` whose release sink is nil, the simulator live-alias path.

import Foundation

struct PublishedSurface: Sendable {
    /// Retains the slot's `LeasedSurface`; its `deinit` releases the
    /// `.daemonCurrent` hold. Never dropped before this value is.
    let owned: LeasedSurface
    /// Device-only lease overlay. Nil for a simulator frame.
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
