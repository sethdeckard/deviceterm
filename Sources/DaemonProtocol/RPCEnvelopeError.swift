// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum RPCEnvelopeError: Error, Equatable, Sendable {
    case notAnObject
    case invalidId  // present but not a non-negative integer fitting in UInt32
    case missingType
    case unknownType(String)
    case invalidError
    case bodyEncodeFailed
}
