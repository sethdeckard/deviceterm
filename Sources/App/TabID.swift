// SPDX-License-Identifier: GPL-3.0-or-later

struct TabID: Hashable, Sendable, Codable, CustomStringConvertible {
    let value: Int
    var description: String { "tab#\(value)" }
}
