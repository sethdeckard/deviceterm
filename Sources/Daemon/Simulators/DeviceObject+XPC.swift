// SPDX-License-Identifier: GPL-3.0-or-later

import ChannelBootstrap
import Foundation
import XPC

/// Native XPC forms of a `DeviceObject`, for a simulator's HID daemon: it takes
/// over a local XPC connection the same values a device takes over its tunnel.
///
/// An XPC dictionary has no order, so a `.fields` map loses its insertion
/// order on the way. The daemon decodes by key and doesn't need it.
extension DeviceObject {
    /// This value as an XPC object.
    var xpcObject: xpc_object_t {
        switch self {
        case .empty:
            return xpc_null_create()

        case let .flag(value):
            return xpc_bool_create(value)

        case let .signed(value):
            return xpc_int64_create(value)

        case let .unsigned(value):
            return xpc_uint64_create(value)

        case let .real(value):
            return xpc_double_create(value)

        case let .text(value):
            return xpc_string_create(value)

        case let .blob(bytes):
            return bytes.withUnsafeBytes { xpc_data_create($0.baseAddress, $0.count) }

        case let .identifier(uuid):
            return withUnsafePointer(to: uuid.uuid) { tuple in
                tuple.withMemoryRebound(to: UInt8.self, capacity: 16) { xpc_uuid_create($0) }
            }

        case let .list(items):
            let array = xpc_array_create(nil, 0)
            for item in items { xpc_array_append_value(array, item.xpcObject) }
            return array

        case let .fields(entries):
            let dictionary = xpc_dictionary_create(nil, nil, 0)
            for entry in entries { xpc_dictionary_set_value(dictionary, entry.name, entry.value.xpcObject) }
            return dictionary
        }
    }

    /// The value an XPC object carries, or `.empty` for a type with no
    /// counterpart here. Dictionary entries come back sorted by key, since XPC
    /// keeps no order to restore.
    init(xpc object: xpc_object_t) {
        let type = xpc_get_type(object)
        switch type {
        case XPC_TYPE_BOOL:
            self = .flag(xpc_bool_get_value(object))

        case XPC_TYPE_INT64:
            self = .signed(xpc_int64_get_value(object))

        case XPC_TYPE_UINT64:
            self = .unsigned(xpc_uint64_get_value(object))

        case XPC_TYPE_DOUBLE:
            self = .real(xpc_double_get_value(object))

        case XPC_TYPE_STRING:
            self = .text(xpc_string_get_string_ptr(object).map { String(cString: $0) } ?? "")

        case XPC_TYPE_DATA:
            let length = xpc_data_get_length(object)
            guard let bytes = xpc_data_get_bytes_ptr(object), length > 0 else {
                self = .blob([])
                return
            }
            self = .blob(Array(UnsafeRawBufferPointer(start: bytes, count: length)))

        case XPC_TYPE_UUID:
            guard let bytes = xpc_uuid_get_bytes(object) else {
                self = .empty
                return
            }
            self = .identifier(NSUUID(uuidBytes: bytes) as UUID)

        case XPC_TYPE_ARRAY:
            var items: [DeviceObject] = []
            xpc_array_apply(object) { _, value in
                items.append(DeviceObject(xpc: value))
                return true
            }
            self = .list(items)

        case XPC_TYPE_DICTIONARY:
            var entries: [(String, DeviceObject)] = []
            xpc_dictionary_apply(object) { key, value in
                entries.append((String(cString: key), DeviceObject(xpc: value)))
                return true
            }
            self = .object(entries.sorted { $0.0 < $1.0 })

        default:
            self = .empty
        }
    }
}
