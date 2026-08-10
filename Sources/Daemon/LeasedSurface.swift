// SPDX-License-Identifier: GPL-3.0-or-later
//
// LeasedSurface: the daemon-current owner of one pool slot's surface.
//
// A `LeasedSurfacePool` hands out a `LeasedSurface` for each acquired
// slot. It holds the slot's `RetainedSurface` (CFRetain + use-count) and,
// on `deinit`, runs a release sink that returns the slot's `.daemonCurrent`
// hold to the pool. So the physical slot is pinned for exactly as long as
// some `PublishedSurface` still references this box: replacing a pane's
// current `PublishedSurface` with a newer one drops the prior box by ARC,
// which frees the slot (once no subscription hold remains).
//
// Simulator frames use the same wrapper with a nil sink: the surface is a
// live CoreSimulator alias the daemon does not own, so there is no
// daemon-current bookkeeping to release.
//
// `@unchecked Sendable`: it wraps a non-Sendable `RetainedSurface` and a
// `@Sendable` sink; the box is immutable after construction and its only
// side effect is the one-shot deinit release.

import Foundation

final class LeasedSurface: @unchecked Sendable {
    let surface: RetainedSurface
    private let onRelease: (@Sendable () -> Void)?

    /// - Parameters:
    ///   - surface: the slot's retained surface.
    ///   - onRelease: released exactly once on `deinit`. Nil for a sim
    ///     frame (no pool slot to free).
    init(surface: RetainedSurface, onRelease: (@Sendable () -> Void)? = nil) {
        self.surface = surface
        self.onRelease = onRelease
    }

    deinit {
        onRelease?()
    }
}
