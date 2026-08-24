// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Serialises a `DeviceObject` to (and from) the device's binary object graph,
/// wrapped in the message envelope the channel carries in DATA frames.
///
/// The byte layout is a fixed device-protocol fact, pinned by deviceterm's own
/// golden vectors. All scalars are little-endian.
///
/// ```
/// wrapper  = magic:u32  flags:u32  bodyLen:u64  messageID:u64  body
/// body     = magic:u32  version:u32  object              // bodyLen bytes
/// object   = tag:u32  payload
/// map      = blobLen:u32  count:u32  entry*              // blobLen spans count+entries
/// entry    = align4(key + NUL)  object
/// text     = align4(len:u32  bytes + NUL)                // len counts the NUL
/// blob     = align4(len:u32  bytes)
/// list     = blobLen:u32  count:u32  object*
/// ```
enum ObjectCoder {
    /// Envelope flag bits.
    enum Flag {
        /// Present on every envelope observed on the wire.
        static let required: UInt32 = 0x0000_0001
        /// Set when the body carries a non-empty map.
        static let carriesPayload: UInt32 = 0x0000_0100
        /// Set when the sender awaits a reply envelope.
        static let awaitsReply: UInt32 = 0x0001_0000
        /// Marks the reply channel's opening control envelope.
        static let channelStart: UInt32 = 0x0040_0000
    }

    // Object-graph type tags.
    private enum Tag: UInt32 {
        case empty = 0x0000_1000
        case flag = 0x0000_2000
        case signed = 0x0000_3000
        case unsigned = 0x0000_4000
        case real = 0x0000_5000
        case date = 0x0000_7000
        case blob = 0x0000_8000
        case text = 0x0000_9000
        case identifier = 0x0000_A000
        case list = 0x0000_E000
        case map = 0x0000_F000
    }

    enum CodecError: Error, Sendable {
        case short
        case wrongMagic
        case badLength
        case unknownTag(UInt32)
    }

    // Envelope + object-graph magic numbers and the payload-graph revision.
    static let envelopeMagic: UInt32 = 0x29B0_0B92
    static let bodyMagic: UInt32 = 0x4213_3742
    static let bodyVersion: UInt32 = 5

    // MARK: Encoding

    /// Frame one object as a request/reply envelope.
    static func encodeEnvelope(
        _ object: DeviceObject,
        messageID: UInt64 = 0,
        awaitingReply: Bool = false
    ) -> [UInt8] {
        var flags = Flag.required
        if object.carriesFields { flags |= Flag.carriesPayload }
        if awaitingReply { flags |= Flag.awaitsReply }
        return assembleEnvelope(flags: flags, messageID: messageID, body: encodeBody(object))
    }

    /// Frame a payload-less control envelope (handshake / terminator). With an
    /// empty body the stored length is zero and no body follows.
    static func encodeControlEnvelope(flags: UInt32, messageID: UInt64 = 0) -> [UInt8] {
        assembleEnvelope(flags: flags, messageID: messageID, body: [])
    }

    /// The total byte count of the first complete envelope in `bytes`, or nil
    /// while it has not fully arrived. Lets the reader carve individual replies
    /// out of DATA frames that split or coalesce envelopes.
    static func envelopeByteCount(in bytes: [UInt8]) throws -> Int? {
        // magic(4) + flags(4) + bodyLen(8) must be present to read the length.
        guard bytes.count >= 16 else { return nil }
        var cursor = Cursor(bytes)
        guard (try? cursor.uint32()) == envelopeMagic else { throw CodecError.wrongMagic }
        _ = try cursor.uint32() // flags
        let bodyLen = try cursor.uint64()
        guard bodyLen <= UInt64(Int.max - 24) else { throw CodecError.badLength }
        let total = 24 + Int(bodyLen)
        return bytes.count >= total ? total : nil
    }

    static func encodeBody(_ object: DeviceObject) -> [UInt8] {
        var out: [UInt8] = []
        out.appendLittleEndian(bodyMagic)
        out.appendLittleEndian(bodyVersion)
        out += encodeObject(object)
        return out
    }

    static func encodeObject(_ object: DeviceObject) -> [UInt8] {
        var out: [UInt8] = []
        switch object {
        case .empty:
            out.appendLittleEndian(Tag.empty.rawValue)

        case let .flag(value):
            out.appendLittleEndian(Tag.flag.rawValue)
            out.appendLittleEndian(UInt32(value ? 1 : 0))

        case let .signed(value):
            out.appendLittleEndian(Tag.signed.rawValue)
            out.appendLittleEndian(UInt64(bitPattern: value))

        case let .unsigned(value):
            out.appendLittleEndian(Tag.unsigned.rawValue)
            out.appendLittleEndian(value)

        case let .real(value):
            out.appendLittleEndian(Tag.real.rawValue)
            out.appendLittleEndian(value.bitPattern)

        case let .text(value):
            out.appendLittleEndian(Tag.text.rawValue)
            out += lengthPrefixedAligned(nulTerminated(value))

        case let .blob(bytes):
            out.appendLittleEndian(Tag.blob.rawValue)
            out += lengthPrefixedAligned(bytes)

        case let .identifier(value):
            out.appendLittleEndian(Tag.identifier.rawValue)
            out += Swift.withUnsafeBytes(of: value.uuid) { Array($0) }

        case let .list(items):
            out.appendLittleEndian(Tag.list.rawValue)
            var blob: [UInt8] = []
            blob.appendLittleEndian(UInt32(items.count))
            for item in items { blob += encodeObject(item) }
            out.appendLittleEndian(UInt32(blob.count))
            out += blob

        case let .fields(entries):
            out.appendLittleEndian(Tag.map.rawValue)
            var blob: [UInt8] = []
            blob.appendLittleEndian(UInt32(entries.count))
            for entry in entries {
                blob += aligned(nulTerminated(entry.name))
                blob += encodeObject(entry.value)
            }
            out.appendLittleEndian(UInt32(blob.count))
            out += blob
        }
        return out
    }

    private static func assembleEnvelope(flags: UInt32, messageID: UInt64, body: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.appendLittleEndian(envelopeMagic)
        out.appendLittleEndian(flags)
        out.appendLittleEndian(UInt64(body.count)) // stored length == body byte count
        out.appendLittleEndian(messageID)
        out += body
        return out
    }

    /// A `len:u32` byte count + payload, the whole block padded to a 4-byte
    /// multiple. Used for text and blob values; text's payload includes its
    /// trailing NUL (counted in `len`), a blob's does not.
    private static func lengthPrefixedAligned(_ payload: [UInt8]) -> [UInt8] {
        var block: [UInt8] = []
        block.appendLittleEndian(UInt32(payload.count))
        block += payload
        return padded(block)
    }

    private static func nulTerminated(_ text: String) -> [UInt8] {
        Array(text.utf8) + [0]
    }

    /// A NUL-terminated key padded to a 4-byte multiple (no length prefix).
    private static func aligned(_ payload: [UInt8]) -> [UInt8] {
        padded(payload)
    }

    private static func padded(_ bytes: [UInt8]) -> [UInt8] {
        let remainder = bytes.count % 4
        return remainder == 0 ? bytes : bytes + [UInt8](repeating: 0, count: 4 - remainder)
    }

    // MARK: Decoding

    /// Decode one complete envelope and return its body object, or nil for a
    /// payload-less control/keep-alive envelope. Throws `short` when the buffer
    /// does not yet hold the whole envelope.
    static func decodeEnvelope(_ bytes: [UInt8]) throws -> DeviceObject? {
        var cursor = Cursor(bytes)
        guard try cursor.uint32() == envelopeMagic else { throw CodecError.wrongMagic }
        _ = try cursor.uint32() // flags
        let bodyLen = try cursor.uint64()
        _ = try cursor.uint64() // messageID
        if bodyLen == 0 { return nil }
        var body = Cursor(try cursor.take(Int(bodyLen)))
        guard try body.uint32() == bodyMagic else { throw CodecError.wrongMagic }
        _ = try body.uint32() // version
        return try decodeObject(&body)
    }

    private static func decodeObject(_ cursor: inout Cursor) throws -> DeviceObject {
        let raw = try cursor.uint32()
        guard let tag = Tag(rawValue: raw) else { throw CodecError.unknownTag(raw) }
        switch tag {
        case .empty:
            return .empty

        case .flag:
            return .flag(try cursor.uint32() != 0)

        case .signed:
            return .signed(Int64(bitPattern: try cursor.uint64()))

        case .unsigned:
            return .unsigned(try cursor.uint64())

        case .real:
            return .real(Double(bitPattern: try cursor.uint64()))

        case .date:
            // The device encodes dates as a 64-bit quantity; surface it as a
            // signed scalar since deviceterm never interprets one further.
            return .signed(Int64(bitPattern: try cursor.uint64()))

        case .text:
            let length = Int(try cursor.uint32())
            let raw = try cursor.take(length)
            try cursor.align4()
            let body = raw.last == 0 ? Array(raw.dropLast()) : raw
            return .text(String(bytes: body, encoding: .utf8) ?? "")

        case .blob:
            let length = Int(try cursor.uint32())
            let bytes = try cursor.take(length)
            try cursor.align4()
            return .blob(bytes)

        case .identifier:
            let bytes = try cursor.take(16)
            return .identifier(UUID(uuid: bytes.withUnsafeBytes { $0.load(as: uuid_t.self) }))

        case .list:
            _ = try cursor.uint32() // blob length
            let count = Int(try cursor.uint32())
            var items: [DeviceObject] = []
            items.reserveCapacity(count)
            for _ in 0..<count { items.append(try decodeObject(&cursor)) }
            return .list(items)

        case .map:
            _ = try cursor.uint32() // blob length
            let count = Int(try cursor.uint32())
            var entries: [DeviceObject.Field] = []
            entries.reserveCapacity(count)
            for _ in 0..<count {
                let name = try cursor.alignedCString()
                let value = try decodeObject(&cursor)
                entries.append(DeviceObject.Field(name: name, value: value))
            }
            return .fields(entries)
        }
    }
}

// MARK: - Byte helpers

extension Array where Element == UInt8 {
    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { self += $0 }
    }

    mutating func appendLittleEndian(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { self += $0 }
    }
}
