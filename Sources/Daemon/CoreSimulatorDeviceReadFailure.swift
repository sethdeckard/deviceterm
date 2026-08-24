// SPDX-License-Identifier: GPL-3.0-or-later

import CoreSimulatorBridge
import Foundation

struct CoreSimulatorDeviceReadFailure: Error, CustomStringConvertible, Equatable, Sendable {
    let message: String

    var description: String { message }
}
