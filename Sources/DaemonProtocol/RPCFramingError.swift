// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum RPCFramingError: Error, Equatable, Sendable {
    /// Length-prefix decoded to a value larger than the configured cap.
    case payloadTooLarge(
        declared:
        Int,
        cap: Int
        )
}
