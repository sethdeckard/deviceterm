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
}
