// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The one payload currency that crosses the channel boundary: an ordered,
/// typed value graph the device's binary object protocol carries in both
/// directions.
///
/// It is deliberately the *only* wire model this target vends. Framing,
/// handshake, and serialisation shapes stay private; a consumer builds a request
/// as a `DeviceObject`, hands it to a `DeviceChannel`, and reads the reply back
/// as one. Field order is preserved end to end because the device's decoder and
/// deviceterm's own fixtures are both order-sensitive.
///
/// `signed` and `unsigned` are separate cases on purpose. Both are 64-bit, but
/// the device protocol distinguishes the two integer encodings by tag, and
/// picking the wrong one is a decode rejection, not a silent coercion.
package enum DeviceObject: Sendable, Equatable {
    case empty
    case flag(Bool)
    case signed(Int64)
    case unsigned(UInt64)
    case real(Double)
    case text(String)
    case blob([UInt8])
    case identifier(UUID)
    case list([DeviceObject])
    case fields([Field])

    /// One ordered entry inside a `.fields` map. A named struct (not a tuple)
    /// so `DeviceObject` stays `Equatable` while keeping insertion order.
    package struct Field: Sendable, Equatable {
        package let name: String
        package let value: DeviceObject

        package init(name: String, value: DeviceObject) {
            self.name = name
            self.value = value
        }
    }

    /// Build a `.fields` map from ordered `(name, value)` pairs. Call sites stay
    /// terse while the stored form remains an `Equatable` `[Field]`.
    package static func object(_ pairs: [(String, DeviceObject)]) -> DeviceObject {
        .fields(pairs.map { Field(name: $0.0, value: $0.1) })
    }
}

// MARK: - Reading values back out

package extension DeviceObject {
    var text: String? {
        if case let .text(value) = self { value } else { nil }
    }

    var signed: Int64? {
        if case let .signed(value) = self { value } else { nil }
    }

    var unsigned: UInt64? {
        if case let .unsigned(value) = self { value } else { nil }
    }

    var flag: Bool? {
        if case let .flag(value) = self { value } else { nil }
    }

    /// True for a `.fields` map that carries at least one entry. That is the
    /// signal separating a real reply from the empty keep-alive frames the
    /// device interleaves.
    var carriesFields: Bool {
        if case let .fields(entries) = self { !entries.isEmpty } else { false }
    }

    /// Depth-first search for the first value stored under `name`, descending
    /// through nested maps and lists. Lets a consumer pull a single field out of
    /// a reply without knowing how deeply the device nested it.
    func firstValue(under name: String) -> DeviceObject? {
        switch self {
        case let .fields(entries):
            for entry in entries {
                if entry.name == name { return entry.value }
                if let found = entry.value.firstValue(under: name) { return found }
            }
            return nil

        case let .list(items):
            for item in items {
                if let found = item.firstValue(under: name) { return found }
            }
            return nil

        default:
            return nil
        }
    }

    /// Look up an entry by name in a `.fields` map; nil for any other case or a
    /// missing name.
    subscript(_ name: String) -> DeviceObject? {
        guard case let .fields(entries) = self else { return nil }
        return entries.first { $0.name == name }?.value
    }
}
