// SPDX-License-Identifier: GPL-3.0-or-later

import CZlibShim
import Foundation

/// Builds the `negotiatorOffer` binary plist that a start-stream request
/// carries. The codec request is expressed as named protobuf fields rather than
/// a captured byte blob; the session id, call id, host identity, and origination
/// timestamp vary at call time. The *layout* (field numbers, nesting, feature
/// lists) is the device protocol fact, pinned by deviceterm's golden vectors.
enum MirrorOffer {
    enum OfferError: Error, Sendable, Equatable {
        case compressionFailed(Int32)
        case plistFailed
        case hostIdentityUnavailable(field: HostIdentity.Field)
    }

    /// The codec profile deviceterm requests for its passive HEVC receiver. The
    /// screen feature list, including its `LTR;` token, is the configuration
    /// validated against sustained high-motion content. The separate
    /// `ltrpEnabled` video-setting flag stays false because this receiver sends
    /// no LTR acknowledgements.
    struct CodecProfile: Sendable, Equatable {
        struct Option: Sendable, Equatable {
            let mediaKind: UInt64
            let priority: UInt64
            let clockRate: UInt64
            let flags: UInt64
        }

        struct RateBand: Sendable, Equatable {
            let profile: UInt64
            let bitrate: UInt64
            let bufferSize: UInt64?
        }

        static let deviceMirror = CodecProfile(
            primaryPayloadType: 123,
            primaryOptions: [
                Option(mediaKind: 1, priority: 1, clockRate: 50_115, flags: 0),
                Option(mediaKind: 1, priority: 2, clockRate: 50_115, flags: 0),
                Option(mediaKind: 1, priority: 1, clockRate: 50_115, flags: 0),
                Option(mediaKind: 1, priority: 2, clockRate: 50_115, flags: 0)
            ],
            primaryFeatureList: "FLS;SW:1;",
            primaryFlags: 1,
            screenPayloadType: 100,
            screenOptions: [
                Option(mediaKind: 1, priority: 1, clockRate: 50_115, flags: 0),
                Option(mediaKind: 1, priority: 2, clockRate: 50_115, flags: 0)
            ],
            screenFeatureList: "FLS;MS:-1;LF:-1;LTR;CABAC;POS:0;EOD:1;HTS:2;RR:3;AR:16/9,5/8;XR:16/9,5/8;",
            screenFlags: 14,
            ltrpEnabled: false,
            maximumFrameRate: 63,
            protocolRevision: "Viceroy 1.7.0",
            // Marker bands (non-zero profile) first, then the plain bitrate bands
            // ascending. Buffer sizes are the device's own pairing and do not
            // track bitrate, so they ride along with their band rather than
            // being sorted themselves.
            rateBands: [
                RateBand(profile: 4_074, bitrate: 0, bufferSize: 16_384),
                RateBand(profile: 1, bitrate: 299, bufferSize: nil),
                RateBand(profile: 16, bitrate: 4_100, bufferSize: nil),
                RateBand(profile: 4, bitrate: 6_500, bufferSize: nil),
                RateBand(profile: 0, bitrate: 6_000_000, bufferSize: 131_072),
                RateBand(profile: 0, bitrate: 20_000_000, bufferSize: 98_304),
                RateBand(profile: 0, bitrate: 40_000_000, bufferSize: 12_288),
                RateBand(profile: 0, bitrate: 60_000_000, bufferSize: 262_144),
                RateBand(profile: 0, bitrate: 75_000_000, bufferSize: 524_288),
                RateBand(profile: 0, bitrate: 100_000_000, bufferSize: 1_048_576)
            ],
            transportKind: 2,
            supportsAudio: 0,
            requiresControlChannel: 1
        )

        let primaryPayloadType: UInt64
        let primaryOptions: [Option]
        let primaryFeatureList: String
        let primaryFlags: UInt64
        let screenPayloadType: UInt64
        let screenOptions: [Option]
        let screenFeatureList: String
        let screenFlags: UInt64
        let ltrpEnabled: Bool
        let maximumFrameRate: UInt64
        let protocolRevision: String
        let rateBands: [RateBand]
        let transportKind: UInt64
        let supportsAudio: UInt64
        let requiresControlChannel: UInt64
    }

    private enum Field {
        case number(Int, UInt64)
        case data(Int, [UInt8])
        case text(Int, String)
    }

    private static let videoNegotiatorMode = 5

    /// The deflate effort for the capabilities blob. Compression is lossless,
    /// so every level inflates to the same blob, but the compressed bytes are
    /// wire-visible and can vary by level.
    private static let compressionLevel: Int32 = 6

    // MARK: Protobuf primitives

    /// A base-128 varint, little-endian groups, high bit as the continuation
    /// flag: the protobuf encoding.
    static func varint(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            out.append(byte)
        } while remaining != 0
        return out
    }

    private static func tag(_ field: Int, wire: Int) -> [UInt8] {
        varint(UInt64((field << 3) | wire))
    }

    private static func encode(_ fields: [Field]) -> [UInt8] {
        fields.flatMap { field -> [UInt8] in
            switch field {
            case let .number(number, value):
                return tag(number, wire: 0) + varint(value)

            case let .data(number, value):
                return tag(number, wire: 2) + varint(UInt64(value.count)) + value

            case let .text(number, value):
                let bytes = Array(value.utf8)
                return tag(number, wire: 2) + varint(UInt64(bytes.count)) + bytes
            }
        }
    }

    // MARK: Origination timestamp

    /// An NTP 64-bit timestamp: the high 32 bits are seconds since 1900-01-01,
    /// the low 32 are a binary fraction of a second. The seconds are masked to
    /// 32 bits, so the 2036 era wrap is deliberate; the field is read modulo
    /// 2^32. The offset is applied signed so a date in the epoch's own first
    /// era (1900 through 1969, negative against the unix epoch) converts
    /// instead of trapping.
    static func ntpTimestamp(at date: Date = Date()) -> UInt64 {
        let unix = date.timeIntervalSince1970
        let whole = unix.rounded(.down)
        let seconds = UInt64(bitPattern: Int64(whole) &+ 2_208_988_800) & 0xFFFF_FFFF
        // `whole` is the floor, so the fraction is in [0, 1) for negative dates too.
        let fraction = UInt64((unix - whole) * 4_294_967_296) & 0xFFFF_FFFF
        return (seconds << 32) | fraction
    }

    // MARK: Offer components

    /// `avcMediaStreamOptionRemoteEndpointInfo`: the host identity.
    static func hostIdentity(_ identity: HostIdentity) -> [UInt8] {
        encode([
            .number(1, 0),
            .number(2, 1),
            .text(3, identity.model),
            .text(4, identity.avConferenceVersion),
            .text(5, identity.osBuild)
        ])
    }

    /// The requested codec capabilities. Every enclosing length is derived from
    /// its encoded child, so the session id uses its natural varint width.
    static func codecCapabilities(
        sessionID: UInt32,
        originationTimestamp: UInt64,
        profile: CodecProfile = .deviceMirror
    ) -> [UInt8] {
        let primary = codec(
            payloadType: profile.primaryPayloadType,
            options: profile.primaryOptions,
            featureList: profile.primaryFeatureList,
            flags: profile.primaryFlags
        )
        let screen = codec(
            payloadType: profile.screenPayloadType,
            options: profile.screenOptions,
            featureList: profile.screenFeatureList,
            flags: profile.screenFlags
        )
        let media = encode([
            .number(1, UInt64(sessionID)),
            .number(2, 0),
            .data(3, primary),
            .data(3, screen),
            .number(7, profile.ltrpEnabled ? 1 : 0),
            .number(8, profile.maximumFrameRate),
            .number(12, 1)
        ])
        var fields: [Field] = [
            .number(1, 1),
            .number(2, 1),
            .data(5, media),
            .text(6, profile.protocolRevision),
            .number(8, 0)
        ]
        fields += profile.rateBands.map { .data(9, rateBand($0)) }
        fields += [
            .number(13, originationTimestamp),
            .number(14, profile.transportKind),
            .number(16, profile.supportsAudio),
            .number(18, profile.requiresControlChannel)
        ]
        return encode(fields)
    }

    private static func codec(
        payloadType: UInt64,
        options: [CodecProfile.Option],
        featureList: String,
        flags: UInt64
    ) -> [UInt8] {
        var fields: [Field] = [.number(1, payloadType)]
        fields += options.map { .data(2, option($0)) }
        fields += [.text(3, featureList), .number(4, flags)]
        return encode(fields)
    }

    private static func option(_ option: CodecProfile.Option) -> [UInt8] {
        encode([
            .number(1, option.mediaKind),
            .number(2, option.priority),
            .number(3, option.clockRate),
            .number(4, option.flags)
        ])
    }

    private static func rateBand(_ band: CodecProfile.RateBand) -> [UInt8] {
        var fields: [Field] = [.number(1, band.profile), .number(2, band.bitrate)]
        if let bufferSize = band.bufferSize { fields.append(.number(3, bufferSize)) }
        return encode(fields)
    }

    // MARK: Assembly

    /// The full video `negotiatorOffer` binary plist for this host.
    static func buildVideo(callID: String, sessionID: UInt32) throws -> Data {
        try buildVideo(callID: callID, sessionID: sessionID, identity: HostIdentity.current())
    }

    /// The same offer built from a caller-supplied identity, so the golden
    /// vectors pin the encoding without reading this machine's metadata. The
    /// origination timestamp defaults to now, so an omitted argument still
    /// exercises the live generator.
    static func buildVideo(
        callID: String,
        sessionID: UInt32,
        identity: HostIdentity,
        originationTimestamp: UInt64 = MirrorOffer.ntpTimestamp()
    ) throws -> Data {
        let endpoint = hostIdentity(identity)
        let blob = try deflate(
            codecCapabilities(sessionID: sessionID, originationTimestamp: originationTimestamp)
        )
        // Dictionary key order is not wire-significant; the device parses this
        // plist by key.
        let plist: [String: Any] = [
            "avcMediaStreamOptionCallID": callID,
            "avcMediaStreamOptionRemoteEndpointInfo": Data(endpoint),
            "avcMediaStreamNegotiatorMode": videoNegotiatorMode,
            "avcMediaStreamNegotiatorMediaBlob": blob
        ]
        do {
            return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        } catch {
            throw OfferError.plistFailed
        }
    }

    /// Compress the capabilities blob through the system libz shim.
    static func deflate(_ input: [UInt8]) throws -> Data {
        var capacity = czlib_compress_bound(input.count)
        var output = [UInt8](repeating: 0, count: capacity)
        let status = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                czlib_compress(source.baseAddress, input.count, destination.baseAddress, &capacity, compressionLevel)
            }
        }
        guard status == 0 else { throw OfferError.compressionFailed(status) }
        return Data(output.prefix(capacity))
    }
}
