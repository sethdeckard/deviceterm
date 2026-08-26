// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import IOSurface

/// The GUI's ownership handle on one daemon-delivered
/// surface (leased for a device pane, unleased for a simulator pane or a
/// kill-switched device). The inverse of the daemon's `RetainedSurface`.
///
/// On a **leased** surface (a device frame the daemon committed a pool
/// hold for), `init` bumps the IOSurface use count and `deinit` decrements
/// it and signals "this generation is released" into the accountant sink,
/// exactly once, by ARC, with no manual flag. The lease dies, and only then is
/// its release signalled, when the surface is no longer current *and*
/// every Metal command buffer that sampled it has completed (each holds a
/// strong ref for its in-flight lifetime). This establishes the required
/// happens-before edge between GPU completion and lease release, so the
/// daemon can't recycle a slot the GPU is still sampling.
///
/// On an **unleased** surface (every simulator frame, and every device
/// frame when `DEVICETERM_SURFACE_LEASES` is off) the sink is nil: no
/// use-count bump, no release, semantically identical to handing around a
/// bare `IOSurfaceRef`.
final class SurfaceLease: @unchecked Sendable {
    /// Identifies one released generation to the accountant. Value type so
    /// the release sink captures no reference back to the lease.
    struct ReleaseKey: Sendable, Hashable {
        let paneId: String
        let subscriptionToken: UUID
        let leaseEpoch: UInt64
        let generation: UInt64
    }

    // Invariant: every stored property is immutable after `init`; the only
    // side effects are the balanced use-count bump/decrement and the
    // single `onRelease` call from `deinit`. That makes concurrent reads
    // of `surface` from any number of Metal command buffers safe without
    // synchronization, which is why `@unchecked Sendable` holds.
    let surface: IOSurfaceRef
    let key: ReleaseKey
    private let onRelease: (@Sendable (ReleaseKey) -> Void)?

    /// The pool generation this frame carries: the join key for tracing
    /// and the value the accountant tracks in its held set. Convenience
    /// accessor over `key.generation`.
    var generation: UInt64 { key.generation }

    init(
        surface: IOSurfaceRef,
        paneId: String,
        subscriptionToken: UUID,
        leaseEpoch: UInt64,
        generation: UInt64,
        onRelease: (@Sendable (ReleaseKey) -> Void)?
    ) {
        self.surface = surface
        self.key = ReleaseKey(
            paneId: paneId,
            subscriptionToken: subscriptionToken,
            leaseEpoch: leaseEpoch,
            generation: generation
        )
        self.onRelease = onRelease
        if onRelease != nil {
            IOSurfaceIncrementUseCount(surface)
        }
    }

    deinit {
        if let onRelease {
            IOSurfaceDecrementUseCount(surface)
            onRelease(key)
        }
    }
}
