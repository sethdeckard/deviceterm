// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Security

public enum CapabilityError: Error, Equatable, Sendable {
    case randomGenerationFailed(
        status:
        Int
        )
}
