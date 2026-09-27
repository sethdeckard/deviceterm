// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
import Foundation
import IOSurface

/// Pool counters for telemetry. Never an authority for correctness.
struct SurfacePoolCounters: Sendable, Equatable {
    var exhaustionDrops = 0
    var rejectedUnknownToken = 0
    var rejectedWrongConnection = 0
    var rejectedUnknownEpoch = 0
    var rejectedAtMostOnce = 0
    var rejectedBelowFrontier = 0
    var delinquentObserved = 0
    var quarantineBudgetExceeded = 0
    var reuseWhileInUse = 0
    /// Failed slot-allocation attempts, including ones followed by reuse of a
    /// free slot still reported in use. Counted apart from `exhaustionDrops`,
    /// which means every slot up to the ceiling was held.
    var allocationFailures = 0
    /// Slots currently allocated across the active and quarantined epochs. A
    /// gauge filled when the counters are snapshotted, not a running count.
    var slotsAllocated = 0
}
