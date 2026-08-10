// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import ChannelBootstrap

/// Project-owned golden vectors for the binary object envelope. Each case pins
/// the device wire shape and proves decoding round-trips the represented value.
/// Bytes live in `Fixtures/object-golden.json`, never as literals in source.
struct ObjectCoderTests {
    struct Golden: Sendable {
        let label: String
        let value: DeviceObject
        let awaitingReply: Bool
        let hex: String
    }

    static let goldens: [Golden] = {
        let hexByLabel = loadFixture()
        func golden(_ label: String, _ value: DeviceObject, awaitingReply: Bool = true) -> Golden {
            Golden(label: label, value: value, awaitingReply: awaitingReply, hex: hexByLabel[label] ?? "")
        }
        return [
            golden("empty", .fields([])),
            golden("str", .object([("k", .text("hi"))])),
            golden("int64", .object([("n", .signed(2))])),
            golden("uint64", .object([("u", .unsigned(58_783))])),
            golden("bool_true", .object([("b", .flag(true))])),
            golden("nested", .object([
                ("a", .object([("b", .text("c"))])),
                ("list", .list([.signed(1), .text("x")]))
            ])),
            golden("init_noreply", .fields([]), awaitingReply: false)
        ]
    }()

    static func loadFixture() -> [String: String] {
        guard let url = Bundle.module.url(forResource: "object-golden", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    @Test("encoder matches the golden object vectors", arguments: goldens)
    func encodeMatchesGolden(golden: Golden) {
        let produced = ObjectCoder.encodeEnvelope(
            golden.value, messageID: 0, awaitingReply: golden.awaitingReply
        )
        #expect(produced.hexString == golden.hex, "mismatch for \(golden.label)")
    }

    @Test("decode round-trips the golden payload", arguments: goldens)
    func decodeRoundTrips(golden: Golden) throws {
        let decoded = try ObjectCoder.decodeEnvelope([UInt8](hexString: golden.hex))
        #expect(decoded == golden.value, "round-trip mismatch for \(golden.label)")
    }

    @Test("control envelope carries the terminator flags")
    func controlEnvelopeMatches() {
        let terminator = ObjectCoder.encodeControlEnvelope(flags: 0x0201)
        #expect(terminator.hexString == Self.loadFixture()["term0201"])
    }

    @Test("payload-less envelope decodes to nil (keep-alive)")
    func payloadlessDecodesNil() throws {
        let terminator = ObjectCoder.encodeControlEnvelope(flags: 0x0201)
        #expect(try ObjectCoder.decodeEnvelope(terminator) == nil)
    }

    @Test("envelope length separates coalesced messages")
    func lengthSeparatesCoalesced() throws {
        let first = ObjectCoder.encodeEnvelope(.object([("a", .signed(1))]))
        let second = ObjectCoder.encodeEnvelope(.object([("b", .signed(2))]))
        let combined = first + second
        #expect(try ObjectCoder.envelopeByteCount(in: combined) == first.count)
        let decoded = try ObjectCoder.decodeEnvelope(Array(combined.prefix(first.count)))
        #expect(decoded == .object([("a", .signed(1))]))
    }

    @Test("a partial envelope reports no length yet")
    func partialEnvelopeIsIncomplete() throws {
        let whole = ObjectCoder.encodeEnvelope(.object([("a", .signed(1))]))
        #expect(try ObjectCoder.envelopeByteCount(in: Array(whole.dropLast())) == nil)
    }

    @Test("an unknown object tag is rejected")
    func unknownTagRejected() {
        // A valid envelope whose body object carries a tag the coder doesn't know.
        var body: [UInt8] = []
        body.appendLittleEndian(ObjectCoder.bodyMagic)
        body.appendLittleEndian(UInt32(5)) // version
        body.appendLittleEndian(UInt32(0x0000_B000)) // no such tag
        var envelope: [UInt8] = []
        envelope.appendLittleEndian(ObjectCoder.envelopeMagic)
        envelope.appendLittleEndian(ObjectCoder.Flag.required)
        envelope.appendLittleEndian(UInt64(body.count))
        envelope.appendLittleEndian(UInt64(0))
        envelope += body
        #expect(throws: ObjectCoder.CodecError.self) {
            _ = try ObjectCoder.decodeEnvelope(envelope)
        }
    }

    @Test("a wrong envelope magic is rejected")
    func wrongMagicRejected() {
        var envelope: [UInt8] = []
        envelope.appendLittleEndian(UInt32(0xDEAD_BEEF))
        envelope.appendLittleEndian(UInt32(0))
        envelope += [UInt8](repeating: 0, count: 16)
        #expect(throws: ObjectCoder.CodecError.self) {
            _ = try ObjectCoder.envelopeByteCount(in: envelope)
        }
    }
}

// MARK: - Hex helpers (test-only)

extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    init(hexString: String) {
        var out: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            out.append(UInt8(hexString[index..<next], radix: 16) ?? 0)
            index = next
        }
        self = out
    }
}
