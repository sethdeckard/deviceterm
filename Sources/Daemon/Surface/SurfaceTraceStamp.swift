// SPDX-License-Identifier: GPL-3.0-or-later

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
