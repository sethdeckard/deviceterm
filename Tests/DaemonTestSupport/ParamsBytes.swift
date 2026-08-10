// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Encode a typed `Params` struct to wire bytes for `RPCEnvelope.body`.
/// Shared across test targets so no `*MethodsTests.swift` file declares
/// its own private version.
public func paramsBytes(_ value: some Codable & Sendable) throws -> Data {
    try JSONEncoder().encode(value)
}
