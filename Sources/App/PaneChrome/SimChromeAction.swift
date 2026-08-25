// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Observation

/// One of the ribbon's interactive actions. Tracked in the chrome view
/// model as `lastUsedAction` so the collapsed ribbon can show the most
/// recently invoked control. Device family selects which subset of
/// cases is reachable in the expanded ribbon
/// (phone/pad → home/rotate; watch → crownPress/up/down; etc.).
enum SimChromeAction: Sendable, Equatable, Hashable {
    case home
    case lock
    case side
    case siri
    case applePay
    case rotateLeft
    case rotateRight
    case screenshot
    case record
    case axInspector
    case crownPress
    case crownUp
    case crownDown
}
