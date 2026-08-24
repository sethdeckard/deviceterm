// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
import Foundation
import IOSurface

/// A delinquent hold surfaced by `diagnoseDelinquent`. Diagnosis only,
/// never a reclaim signal.
struct DelinquentHold: Sendable, Equatable {
    let epoch: UInt64
    let generation: UInt64
    let token: UUID
    let ageNanoseconds: UInt64
}
