// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One request frame: a method plus a flat string-keyed parameter bag.
///
/// Every scalar the harness needs (paths, bundle ids, coordinates,
/// shortcuts) serializes as a string; the responder parses per method.
/// A flat `[String: String]` keeps the wire shape trivial and the
/// Codable synthesis dependency-free.
public struct UITestRequest: Codable, Sendable, Equatable {
    public let method: UITestMethod
    public var params: [String: String]

    public init(method: UITestMethod, params: [String: String] = [:]) {
        self.method = method
        self.params = params
    }
}
