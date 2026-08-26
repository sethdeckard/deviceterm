// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A forward cursor over a byte buffer with little-endian readers and 4-byte
/// alignment: the read side of the CoreDevice object wire format.
///
/// Paired with the encoder in `ObjectCoder.swift`. The alignment rules here
/// mirror the encoder's padding exactly; the two must move together.
struct Cursor {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= bytes.count else { throw ObjectCoder.CodecError.short }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func uint32() throws -> UInt32 {
        try take(4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    mutating func uint64() throws -> UInt64 {
        try take(8).withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
    }

    mutating func align4() throws {
        let remainder = offset % 4
        if remainder != 0 { _ = try take(4 - remainder) }
    }

    mutating func alignedCString() throws -> String {
        var raw: [UInt8] = []
        while true {
            let byte = try take(1)[0]
            if byte == 0 { break }
            raw.append(byte)
        }
        try align4()
        return String(bytes: raw, encoding: .utf8) ?? ""
    }
}
