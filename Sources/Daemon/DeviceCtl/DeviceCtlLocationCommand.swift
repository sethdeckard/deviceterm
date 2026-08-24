// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// One `devicectl device simulate location` invocation.
enum DeviceCtlLocationCommand: Equatable, Sendable {
    case coordinate(latitude: Double, longitude: Double)
    case scenario(name: String)
    /// `routePath` is a file this type wrote, holding the JSON
    /// `--route-file` expects.
    case route(routePath: String)
    case list
    case clear
}
