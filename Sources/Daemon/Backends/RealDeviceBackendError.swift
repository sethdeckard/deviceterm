// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import CoreVideo
import DaemonProtocol
import Foundation
import InteractionRelay
import IOSurface
import MirrorPipeline
import SurfaceTrace

/// Errors specific to a physical-device backend, surfaced to the coordinator's
/// generic bridge-error path (wrapped as `bridgeFailed`).
enum RealDeviceBackendError: Error, CustomStringConvertible {
    case unsupported(verb: String)

    var description: String {
        switch self {
        case let .unsupported(verb):
            return "\(verb) is not supported on physical devices yet"
        }
    }
}
