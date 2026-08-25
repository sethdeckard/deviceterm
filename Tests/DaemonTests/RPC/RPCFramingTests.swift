// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

// MARK: - Encode

@Test
func encodeEmptyPayloadProducesFourZeroBytes() {
    let frame = RPCFraming.encode(Data())
    #expect(frame == Data([0, 0, 0, 0]))
}

@Test
func encodePrependsBigEndianLength() {
    let payload = Data("abc".utf8)  // 3 bytes
    let frame = RPCFraming.encode(payload)
    #expect(frame == Data([0, 0, 0, 3, 0x61, 0x62, 0x63]))
}

@Test
func decodeNextConsumesOnlyTheFirstFrameLeavingTheTail() throws {
    // The `deviceterm events` handshake reads the subscription ack out of a
    // buffer that may ALSO already hold the first event (they can arrive in one
    // read). Decoding must consume only the ack's bytes and leave the event's,
    // so a shared persistent buffer preserves it. This pins that mechanism.
    let ack = RPCFraming.encode(Data("ack".utf8))
    let event = RPCFraming.encode(Data("event".utf8))
    var buffer = ack + event

    let first = try #require(try RPCFraming.decodeNext(from: buffer))
    #expect(first.payload == Data("ack".utf8))
    buffer.removeFirst(first.consumed)
    // The event's bytes survived. Decoding again yields it, not a truncation.
    let second = try #require(try RPCFraming.decodeNext(from: buffer))
    #expect(second.payload == Data("event".utf8))
    buffer.removeFirst(second.consumed)
    #expect(buffer.isEmpty)
}

@Test
func encodeHandlesLargePayload() {
    // 70_000 bytes, > 65_535 so the high half of the BE length is
    // non-zero. Catches accidental UInt16 / little-endian regressions.
    let payload = Data(repeating: 0x41, count: 70_000)
    let frame = RPCFraming.encode(payload)
    let prefix = frame.prefix(4)
    #expect(prefix == Data([0x00, 0x01, 0x11, 0x70]))
    #expect(frame.count == 4 + 70_000)
}

// MARK: - Decode (happy path)

@Test
func decodeSingleFrameReturnsPayloadAndConsumed() throws {
    let payload = Data("hello".utf8)
    let buffer = RPCFraming.encode(payload)
    let result = try #require(try RPCFraming.decodeNext(from: buffer))
    #expect(result.payload == payload)
    #expect(result.consumed == buffer.count)
}

@Test
func decodeReturnsExactlyOneFrameFromAConcatenatedBuffer() throws {
    // Two frames glued together; decodeNext should only consume the first.
    let first = RPCFraming.encode(Data("AAA".utf8))
    let second = RPCFraming.encode(Data("BBBB".utf8))
    let buffer = first + second
    let result = try #require(try RPCFraming.decodeNext(from: buffer))
    #expect(result.payload == Data("AAA".utf8))
    #expect(result.consumed == first.count)
    // Drain and decode the next.
    let remaining = buffer.subdata(in: result.consumed..<buffer.count)
    let next = try #require(try RPCFraming.decodeNext(from: remaining))
    #expect(next.payload == Data("BBBB".utf8))
}

// MARK: - Decode (incomplete buffer)

@Test
func decodeReturnsNilWhenPrefixIncomplete() throws {
    #expect(try RPCFraming.decodeNext(from: Data()) == nil)
    #expect(try RPCFraming.decodeNext(from: Data([0])) == nil)
    #expect(try RPCFraming.decodeNext(from: Data([0, 0, 0])) == nil)
}

@Test
func decodeReturnsNilWhenPayloadIncomplete() throws {
    // Prefix says 5 bytes coming, buffer only has 4. Still waiting.
    let buffer = Data([0, 0, 0, 5, 0x41, 0x41, 0x41, 0x41])
    #expect(try RPCFraming.decodeNext(from: buffer) == nil)
}

@Test
func decodeZeroLengthPayloadReturnsEmptyPayload() throws {
    let buffer = Data([0, 0, 0, 0])
    let result = try #require(try RPCFraming.decodeNext(from: buffer))
    #expect(result.payload.isEmpty)
    #expect(result.consumed == 4)
}

// MARK: - Decode (cap enforcement)

@Test
func decodeThrowsWhenLengthExceedsCap() {
    // 0x00 0x00 0x00 0x10 = 16 byte length declared, with cap of 8.
    let buffer = Data([0, 0, 0, 16, 0x41, 0x41, 0x41, 0x41])
    #expect(throws: RPCFramingError.payloadTooLarge(declared: 16, cap: 8)) {
        _ = try RPCFraming.decodeNext(from: buffer, cap: 8)
    }
}

@Test
func decodeAcceptsLengthExactlyAtCap() throws {
    let payload = Data(repeating: 0x42, count: 8)
    let buffer = RPCFraming.encode(payload)
    let result = try #require(try RPCFraming.decodeNext(from: buffer, cap: 8))
    #expect(result.payload == payload)
}

// MARK: - Decode (slice semantics)

@Test
func decodeHandlesBufferWithNonZeroStartIndex() throws {
    // Construct a Data slice whose startIndex isn't 0. Verifies the
    // implementation uses `index(_:offsetBy:)` instead of raw integer
    // offsets that would index off-by-startIndex.
    let prefix = Data([0xDE, 0xAD])
    let frame = RPCFraming.encode(Data("xyz".utf8))
    let combined = prefix + frame
    let slice = combined.suffix(from: prefix.count)
    let result = try #require(try RPCFraming.decodeNext(from: slice))
    #expect(result.payload == Data("xyz".utf8))
}

// MARK: - Round-trip

@Test(
    "framing round-trip",
    arguments: [
    Data(),
    Data("a".utf8),
    Data(repeating: 0xFF, count: 257),
    Data(repeating: 0x00, count: 1_024),
    Data("the quick brown fox jumps over the lazy dog".utf8)
    ]
    )
func roundTripPreservesPayload(payload: Data) throws {
    let frame = RPCFraming.encode(payload)
    let result = try #require(try RPCFraming.decodeNext(from: frame))
    #expect(result.payload == payload)
    #expect(result.consumed == frame.count)
}
