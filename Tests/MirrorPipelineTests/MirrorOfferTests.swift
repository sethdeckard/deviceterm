// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import MirrorPipeline

/// The shipping negotiator offer, validated against local vectors built from
/// fixed synthetic inputs: a session id, a call id, an obviously-fake host
/// identity, and a fixed test-only instant, never a captured device response,
/// this machine's real metadata, or a real call's clock reading. The vectors are
/// therefore deterministic and carry no device or host data. They pin the
/// encoding of the media-start path, including deviceterm's chosen zlib level 6.
struct MirrorOfferTests {
    struct Golden: Decodable {
        let sessionID: UInt32
        let callID: String
        let hostModel: String
        let hostAVConferenceVersion: String
        let hostOSBuild: String
        let endpointHex: String
        let blobHex: String
        let compHex: String
        let offerHex: String
    }

    /// A `HostMetadataSource` that answers from fixed values, or throws for the
    /// nominated field, so the resolver is exercised without reading this
    /// machine's sysctls or private frameworks.
    struct FakeHostMetadata: HostMetadataSource {
        var identity: HostIdentity
        var failing: HostIdentity.Field?

        private func value(_ resolved: String, field: HostIdentity.Field) throws -> String {
            guard failing != field else {
                throw MirrorOffer.OfferError.hostIdentityUnavailable(field: field)
            }
            return resolved
        }

        func model() throws -> String { try value(identity.model, field: .model) }

        func avConferenceVersion() throws -> String {
            try value(identity.avConferenceVersion, field: .avConferenceVersion)
        }

        func osBuild() throws -> String { try value(identity.osBuild, field: .osBuild) }
    }

    static let golden: Golden = {
        guard let url = Bundle.module.url(forResource: "media-offer-golden", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(Golden.self, from: data) else {
            return Golden(
                sessionID: 0,
                callID: "",
                hostModel: "",
                hostAVConferenceVersion: "",
                hostOSBuild: "",
                endpointHex: "",
                blobHex: "",
                compHex: "",
                offerHex: ""
            )
        }
        return decoded
    }()

    static var goldenIdentity: HostIdentity {
        HostIdentity(
            model: golden.hostModel,
            avConferenceVersion: golden.hostAVConferenceVersion,
            osBuild: golden.hostOSBuild
        )
    }

    /// The seam the vectors are frozen at: 2001-01-01T00:00:00Z, zero fraction.
    /// A production offer stamps the moment it is built, so this instant appears
    /// only in the fixtures.
    static var goldenTimestamp: UInt64 {
        MirrorOffer.ntpTimestamp(at: Date(timeIntervalSinceReferenceDate: 0))
    }

    static func count(of needle: [UInt8], in haystack: [UInt8]) -> Int {
        guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
        var total = 0
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<start + needle.count]) == needle {
            total += 1
        }
        return total
    }

    /// Inflate an RFC-1950 stream. Foundation's `.zlib` algorithm is raw DEFLATE
    /// (RFC 1951), so the two-byte stream header and the four-byte Adler-32
    /// trailer come off first. Inspection only: production never reads an offer
    /// back, it only encodes one.
    static func inflate(_ data: Data) throws -> [UInt8] {
        let body = data.dropFirst(2).dropLast(4)
        return [UInt8](try (Data(body) as NSData).decompressed(using: .zlib))
    }

    /// The value of a top-level varint field in a protobuf message, or nil if it
    /// is absent. Understands just enough of the encoding to walk past
    /// length-delimited fields; inspection only, not a second codec.
    static func varintField(_ number: Int, in bytes: [UInt8]) -> UInt64? {
        var index = 0

        func nextVarint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift >= 64 { return nil }
            }
            return nil
        }

        while index < bytes.count {
            guard let tag = nextVarint() else { return nil }
            let field = Int(tag >> 3)
            switch tag & 0x7 {
            case 0:
                guard let value = nextVarint() else { return nil }
                if field == number { return value }

            case 2:
                guard let length = nextVarint(), index + Int(length) <= bytes.count else { return nil }
                index += Int(length)

            default:
                return nil
            }
        }
        return nil
    }

    /// Field 13 of the capabilities blob carried by an assembled offer: binary
    /// plist, then the compressed media blob, then the protobuf walk.
    static func originationTimestamp(inOffer offer: Data) throws -> UInt64? {
        let plist = try PropertyListSerialization.propertyList(from: offer, options: [], format: nil)
        guard let dict = plist as? [String: Any],
            let blob = dict["avcMediaStreamNegotiatorMediaBlob"] as? Data else { return nil }
        return varintField(13, in: try inflate(blob))
    }

    @Test("host identity protobuf matches the local vector")
    func hostIdentityMatches() {
        let bytes = MirrorOffer.hostIdentity(Self.goldenIdentity)
        #expect(Data(bytes).hexLower == Self.golden.endpointHex)
    }

    @Test("the resolver assembles an identity from its metadata source")
    func resolvesHostIdentity() throws {
        let expected = Self.goldenIdentity
        let resolved = try HostIdentity.resolve(using: FakeHostMetadata(identity: expected))
        #expect(resolved == expected)
    }

    @Test(
        "an unreadable field throws rather than substituting a blank",
        arguments: [HostIdentity.Field.model, .avConferenceVersion, .osBuild]
    )
    func unreadableFieldThrows(field: HostIdentity.Field) {
        let source = FakeHostMetadata(identity: Self.goldenIdentity, failing: field)
        #expect(throws: MirrorOffer.OfferError.hostIdentityUnavailable(field: field)) {
            try HostIdentity.resolve(using: source)
        }
    }

    @Test("codec capabilities blob matches the structured profile vector")
    func capabilitiesBlobMatches() {
        let bytes = MirrorOffer.codecCapabilities(
            sessionID: Self.golden.sessionID,
            originationTimestamp: Self.goldenTimestamp
        )
        #expect(Data(bytes).hexLower == Self.golden.blobHex)
    }

    @Test("NTP timestamps count seconds from 1900 with a binary fraction")
    func ntpTimestampConversion() {
        // 2001-01-01T00:00:00Z is 3_187_296_000 seconds after 1900-01-01.
        let epoch = MirrorOffer.ntpTimestamp(at: Date(timeIntervalSinceReferenceDate: 0))
        #expect(epoch >> 32 == 3_187_296_000)
        #expect(epoch & 0xFFFF_FFFF == 0)

        // A half second in is the fraction's high bit and nothing else.
        let half = MirrorOffer.ntpTimestamp(at: Date(timeIntervalSinceReferenceDate: 0.5))
        #expect(half >> 32 == 3_187_296_000)
        #expect(half & 0xFFFF_FFFF == 0x8000_0000)

        // The unix epoch itself pins the 1900 offset directly.
        #expect(MirrorOffer.ntpTimestamp(at: Date(timeIntervalSince1970: 0)) >> 32 == 2_208_988_800)
    }

    @Test("the seconds field wraps at 2^32 rather than overflowing")
    func ntpTimestampWraps() {
        // The first second of the next NTP era: seconds masked back to zero.
        let wrapped = MirrorOffer.ntpTimestamp(at: Date(timeIntervalSince1970: 4_294_967_296 - 2_208_988_800))
        #expect(wrapped >> 32 == 0)
    }

    @Test("dates in the epoch's own first era convert rather than trapping")
    func ntpTimestampBeforeUnixEpoch() {
        // 1900-01-01T00:00:00Z is the epoch itself: zero seconds, zero fraction.
        #expect(MirrorOffer.ntpTimestamp(at: Date(timeIntervalSince1970: -2_208_988_800)) == 0)

        // A day before the unix epoch is a day short of the 1970 offset, and the
        // fraction stays in [0, 1) because the seconds are floored, not truncated.
        let beforeEpoch = MirrorOffer.ntpTimestamp(at: Date(timeIntervalSince1970: -86_400 + 0.5))
        #expect(beforeEpoch >> 32 == 2_208_988_800 - 86_400)
        #expect(beforeEpoch & 0xFFFF_FFFF == 0x8000_0000)
    }

    @Test("an assembled offer carries the moment it was built")
    func offerCarriesLiveTimestamp() throws {
        // Omitting the timestamp exercises the production default; the identity
        // stays synthetic so this reads no host metadata.
        let before = MirrorOffer.ntpTimestamp()
        let offer = try MirrorOffer.buildVideo(
            callID: Self.golden.callID,
            sessionID: Self.golden.sessionID,
            identity: Self.goldenIdentity
        )
        let after = MirrorOffer.ntpTimestamp()

        let decoded = try Self.originationTimestamp(inOffer: offer)
        let stamped = try #require(decoded)
        #expect(stamped >= before)
        #expect(stamped <= after)
        #expect(stamped != Self.goldenTimestamp)
    }

    @Test("the reader recovers the timestamp an offer was built with")
    func readerRecoversSeamTimestamp() throws {
        let offer = try MirrorOffer.buildVideo(
            callID: Self.golden.callID,
            sessionID: Self.golden.sessionID,
            identity: Self.goldenIdentity,
            originationTimestamp: Self.goldenTimestamp
        )
        #expect(try Self.originationTimestamp(inOffer: offer) == Self.goldenTimestamp)
    }

    @Test("level-6 zlib compression matches the local vector")
    func zlibMatches() throws {
        let blob = [UInt8](hexString: Self.golden.blobHex)
        let compressed = try MirrorOffer.deflate(blob)
        #expect(compressed.hexLower == Self.golden.compHex)
    }

    @Test("full negotiator offer matches the local plist vector")
    func fullOfferMatches() throws {
        // A binary plist dict is unordered; the device parses by key, so key
        // order isn't wire-significant. Compare decoded plists; the components
        // themselves are pinned byte for byte above.
        let offer = try MirrorOffer.buildVideo(
            callID: Self.golden.callID,
            sessionID: Self.golden.sessionID,
            identity: Self.goldenIdentity,
            originationTimestamp: Self.goldenTimestamp
        )
        let mine = try PropertyListSerialization.propertyList(from: offer, options: [], format: nil) as? [String: Any]
        let expected = try PropertyListSerialization.propertyList(
            from: Data([UInt8](hexString: Self.golden.offerHex)), options: [], format: nil
        ) as? [String: Any]
        #expect(NSDictionary(dictionary: mine ?? [:]).isEqual(to: expected ?? [:]))
    }

    @Test("varint encodes multi-byte values like protobuf")
    func varintEncoding() {
        #expect(MirrorOffer.varint(0) == [0x00])
        #expect(MirrorOffer.varint(1) == [0x01])
        #expect(MirrorOffer.varint(300) == [0xAC, 0x02])
        #expect(MirrorOffer.varint(16_384) == [0x80, 0x80, 0x01])
    }

    @Test("the profile uses a naturally sized session varint")
    func naturalSessionVarint() {
        let shortSession = MirrorOffer.codecCapabilities(
            sessionID: 42,
            originationTimestamp: Self.goldenTimestamp
        )
        let fiveByteSession = MirrorOffer.codecCapabilities(
            sessionID: Self.golden.sessionID,
            originationTimestamp: Self.goldenTimestamp
        )
        #expect(Array(shortSession.prefix(9)) == [0x08, 0x01, 0x10, 0x01, 0x2A, 0xB4, 0x01, 0x08, 0x2A])
        #expect(shortSession.count == fiveByteSession.count - 4)
    }

    @Test("the shipping blob carries the production feature list with ltrpEnabled false")
    func shippingBlobShape() {
        let blob = MirrorOffer.codecCapabilities(
            sessionID: Self.golden.sessionID,
            originationTimestamp: Self.goldenTimestamp
        )
        let production = "FLS;MS:-1;LF:-1;LTR;CABAC;POS:0;EOD:1;HTS:2;RR:3;AR:16/9,5/8;XR:16/9,5/8;"
        #expect(Self.count(of: Array(production.utf8), in: blob) == 1)
        // `FLS;VRAE:0;SW:1;` corrupts high-motion frames and must be absent.
        #expect(Self.count(of: Array("FLS;VRAE:0;SW:1;".utf8), in: blob) == 0)
        // Video-settings fields 4, 7, and 8: flags 14, ltrpEnabled false, maximum frame rate 63.
        #expect(Self.count(of: [0x20, 0x0e, 0x38, 0x00, 0x40, 0x3f], in: blob) == 1)
        // The offer must never emit the same field context with ltrpEnabled true.
        #expect(Self.count(of: [0x20, 0x0e, 0x38, 0x01, 0x40, 0x3f], in: blob) == 0)
    }
}

extension Data {
    var hexLower: String { map { String(format: "%02x", $0) }.joined() }
}

extension Array where Element == UInt8 {
    init(hexString: String) {
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            bytes.append(UInt8(hexString[index..<next], radix: 16) ?? 0)
            index = next
        }
        self = bytes
    }
}
