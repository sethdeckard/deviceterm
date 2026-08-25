// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import SurfaceTrace

/// The context the content view hands the renderer for a traced device
/// frame. `expectedTraceId` is the pool generation the GUI intended to
/// render (the wire sequence); the consumer records it alongside the id it
/// scans back after the delay, for offline comparison.
struct SurfaceConsumerTrace: Sendable {
    let paneId: String
    let sink: SurfaceTraceSink
    let delayNanoseconds: UInt64
    let expectedTraceId: UInt64
}
