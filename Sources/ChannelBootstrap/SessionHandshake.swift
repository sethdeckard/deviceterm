// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The fixed opening transcript the device tunnel's transport expects, kept as a
/// value so its ordering and flow-control advertisement stay inspectable without
/// a live socket.
///
/// Opening a session means: send the connection preface, advertise SETTINGS and
/// a connection-level window, open the root and reply streams, and prime them
/// with the initial and reply-channel control envelopes. The peer answers with
/// its own SETTINGS; anything else means the far end is not the transport
/// deviceterm expects.
struct SessionHandshake {
    private enum Stage {
        case fresh
        case awaitingPeerSettings
        case established
    }

    static let preface = Array("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
    static let rootStream: UInt32 = 1
    static let replyStream: UInt32 = 3
    static let maxConcurrentStreams: UInt32 = 100
    static let initialWindowSize: UInt32 = 16 * 1_024 * 1_024
    static let connectionWindowIncrement: UInt32 = 16_711_681

    // The root stream's terminator control envelope flags. This is a fixed
    // literal on the wire, not a composition of the named flag bits.
    private static let terminatorFlags: UInt32 = 0x0201

    private var stage = Stage.fresh

    /// The ordered byte blocks that open a session, one send each.
    mutating func openingBlocks() -> [[UInt8]] {
        precondition(stage == .fresh)
        stage = .awaitingPeerSettings

        let settings = FrameTransport.settings([
            (0x3, Self.maxConcurrentStreams),
            (0x4, Self.initialWindowSize)
        ])
        let window = FrameTransport.windowUpdate(streamID: 0, increment: Self.connectionWindowIncrement)
        let initEnvelope = ObjectCoder.encodeEnvelope(.fields([]), messageID: 0, awaitingReply: false)
        let terminator = ObjectCoder.encodeControlEnvelope(flags: Self.terminatorFlags)
        let replyEnvelope = ObjectCoder.encodeControlEnvelope(
            flags: ObjectCoder.Flag.required | ObjectCoder.Flag.channelStart
        )
        return [
            Self.preface,
            settings,
            window,
            FrameTransport.openStream(streamID: Self.rootStream),
            FrameTransport.data(streamID: Self.rootStream, initEnvelope),
            FrameTransport.openStream(streamID: Self.replyStream),
            FrameTransport.data(streamID: Self.rootStream, terminator),
            FrameTransport.data(streamID: Self.replyStream, replyEnvelope)
        ]
    }

    /// Accept the peer's opening frame, which must be a stream-0 SETTINGS.
    mutating func acceptPeerFrame(_ header: FrameTransport.Header) throws {
        guard stage == .awaitingPeerSettings else {
            throw WireCompatibilityError.unexpectedFrame(context: "session handshake stage")
        }
        guard header.kind == .settings, header.streamID == 0 else {
            throw WireCompatibilityError.unexpectedFrame(context: "session opening frame")
        }
        stage = .established
    }
}
