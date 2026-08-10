// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The narrow slice of HTTP/2 framing the device tunnel's transport speaks.
///
/// The device never negotiates HPACK: streams open with empty HEADERS frames
/// and every payload rides in DATA frames, so only a handful of frame kinds
/// matter. Everything here is a pure value transform with no I/O, either
/// building the byte form of a frame or parsing a 9-byte header.
enum FrameTransport {
    /// Frame kinds deviceterm emits or reacts to. A header whose type byte is
    /// none of these parses with a nil `kind`, and the reader skips its body.
    enum Kind: UInt8 {
        case data = 0x0
        case headers = 0x1
        case resetStream = 0x3
        case settings = 0x4
        case ping = 0x6
        case goAway = 0x7
        case windowUpdate = 0x8
    }

    /// Frame flag bits, reused across kinds.
    enum Flag {
        static let endStream: UInt8 = 0x1 // DATA / HEADERS
        static let acknowledge: UInt8 = 0x1 // SETTINGS / PING
        static let endHeaders: UInt8 = 0x4 // HEADERS
    }

    /// A parsed frame header. `kind` is nil for a frame type deviceterm does not
    /// model, so the reader can drain and skip its body.
    struct Header {
        let kind: Kind?
        let flags: UInt8
        let streamID: UInt32
        let length: Int
    }

    /// The fixed 9-byte frame header prefix.
    static let headerLength = 9

    // MARK: Frame construction

    /// A SETTINGS frame from `(identifier, value)` pairs, each written as the
    /// 6-byte big-endian id/value the spec requires.
    static func settings(_ pairs: [(UInt16, UInt32)]) -> [UInt8] {
        var body: [UInt8] = []
        for (identifier, value) in pairs {
            body.append(UInt8((identifier >> 8) & 0xFF))
            body.append(UInt8(identifier & 0xFF))
            body.append(UInt8((value >> 24) & 0xFF))
            body.append(UInt8((value >> 16) & 0xFF))
            body.append(UInt8((value >> 8) & 0xFF))
            body.append(UInt8(value & 0xFF))
        }
        return frame(kind: .settings, flags: 0, streamID: 0, payload: body)
    }

    static func settingsAcknowledge() -> [UInt8] {
        frame(kind: .settings, flags: Flag.acknowledge, streamID: 0, payload: [])
    }

    static func windowUpdate(streamID: UInt32, increment: UInt32) -> [UInt8] {
        let value = increment & 0x7FFF_FFFF
        let body: [UInt8] = [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)
        ]
        return frame(kind: .windowUpdate, flags: 0, streamID: streamID, payload: body)
    }

    /// An empty HEADERS frame, which is how a stream is opened without HPACK.
    static func openStream(streamID: UInt32) -> [UInt8] {
        frame(kind: .headers, flags: Flag.endHeaders, streamID: streamID, payload: [])
    }

    static func data(streamID: UInt32, _ payload: [UInt8]) -> [UInt8] {
        frame(kind: .data, flags: 0, streamID: streamID, payload: payload)
    }

    /// Serialise a frame: 9-byte header (24-bit length, type, flags, 31-bit
    /// stream id) followed by the payload.
    static func frame(kind: Kind, flags: UInt8, streamID: UInt32, payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        let length = UInt32(payload.count)
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(length & 0xFF))
        out.append(kind.rawValue)
        out.append(flags)
        let stream = streamID & 0x7FFF_FFFF
        out.append(UInt8((stream >> 24) & 0xFF))
        out.append(UInt8((stream >> 16) & 0xFF))
        out.append(UInt8((stream >> 8) & 0xFF))
        out.append(UInt8(stream & 0xFF))
        out += payload
        return out
    }

    /// Parse the 9-byte frame header.
    static func parseHeader(_ header: [UInt8]) -> Header {
        let length = (Int(header[0]) << 16) | (Int(header[1]) << 8) | Int(header[2])
        let streamID = (UInt32(header[5] & 0x7F) << 24) | (UInt32(header[6]) << 16)
            | (UInt32(header[7]) << 8) | UInt32(header[8])
        return Header(kind: Kind(rawValue: header[3]), flags: header[4], streamID: streamID, length: length)
    }
}
