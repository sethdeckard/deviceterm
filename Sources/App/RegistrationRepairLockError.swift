// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum RegistrationRepairLockError: Error, CustomStringConvertible {
    case cannotOpen(String)
    case cannotLock(String)

    var description: String {
        switch self {
        case let .cannotOpen(reason):
            return "could not open the repair lock: \(reason)"

        case let .cannotLock(reason):
            return "could not take the repair lock: \(reason)"
        }
    }
}
