// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import ChannelBootstrap

/// Hermetic checks for the HTTP/2 framing subset and the session opening state.
struct FrameTransportTests {
    @Test("a DATA frame header round-trips")
    func dataHeaderRoundTrip() {
        let bytes = FrameTransport.data(streamID: 3, [0xDE, 0xAD, 0xBE, 0xEF])
        #expect(bytes.count == 13) // 9-byte header + 4-byte payload
        let header = FrameTransport.parseHeader(Array(bytes.prefix(9)))
        #expect(header.kind == .data)
        #expect(header.flags == 0)
        #expect(header.streamID == 3)
        #expect(header.length == 4)
        #expect(Array(bytes.suffix(4)) == [0xDE, 0xAD, 0xBE, 0xEF])
    }

    @Test("a SETTINGS frame encodes id/value pairs big-endian")
    func settingsEncoding() {
        let body = Array(FrameTransport.settings([(0x3, 100), (0x4, 16 * 1_024 * 1_024)]).suffix(12))
        #expect(body == [
            0x00, 0x03, 0x00, 0x00, 0x00, 0x64, // MAX_CONCURRENT_STREAMS = 100
            0x00, 0x04, 0x01, 0x00, 0x00, 0x00 // INITIAL_WINDOW_SIZE = 16 MiB
        ])
    }

    @Test("an empty HEADERS frame opens a stream with END_HEADERS and no payload")
    func openStreamFrame() {
        let bytes = FrameTransport.openStream(streamID: 1)
        #expect(bytes.count == 9)
        let header = FrameTransport.parseHeader(bytes)
        #expect(header.kind == .headers)
        #expect(header.flags == FrameTransport.Flag.endHeaders)
        #expect(header.streamID == 1)
        #expect(header.length == 0)
    }

    @Test("the opening transcript sends the required block sequence")
    func openingTranscript() {
        var handshake = SessionHandshake()
        let blocks = handshake.openingBlocks()
        #expect(blocks.count == 8)
        #expect(blocks[0] == SessionHandshake.preface)

        let root = FrameTransport.parseHeader(Array(blocks[3].prefix(FrameTransport.headerLength)))
        let reply = FrameTransport.parseHeader(Array(blocks[5].prefix(FrameTransport.headerLength)))
        let window = FrameTransport.parseHeader(Array(blocks[2].prefix(FrameTransport.headerLength)))
        #expect(root.kind == .headers)
        #expect(root.streamID == SessionHandshake.rootStream)
        #expect(reply.kind == .headers)
        #expect(reply.streamID == SessionHandshake.replyStream)
        #expect(window.kind == .windowUpdate)
        #expect(window.streamID == 0)
        #expect(Array(blocks[2].suffix(4)) == [0x00, 0xFF, 0x00, 0x01])
    }

    @Test("a non-settings opening frame from the peer is rejected")
    func rejectsUnexpectedPeerFrame() {
        var handshake = SessionHandshake()
        _ = handshake.openingBlocks()
        let header = FrameTransport.Header(kind: .ping, flags: 0, streamID: 0, length: 0)
        #expect(throws: WireCompatibilityError.unexpectedFrame(context: "session opening frame")) {
            try handshake.acceptPeerFrame(header)
        }
    }
}
