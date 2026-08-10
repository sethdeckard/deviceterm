// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One open channel to a device service over the tunnel.
///
/// Each device service gets its own channel: many services close the channel
/// after a single reply, so sharing one would be fragile. The actor serialises
/// its own request/reply exchanges, letting one complete before the next begins
/// so a reply can't be misattributed, and hands the raw byte transport off to a
/// `ByteChannel`.
///
/// Three ways to talk to a service: `emit` fires a report with no reply
/// (the streaming input path), `request` sends a payload and awaits the reply,
/// and `invoke` wraps a CoreDevice feature call (request + reply, unwrapping the
/// result). Message selectors are opaque strings supplied by the caller; this
/// target never names a device feature itself.
package actor DeviceChannel {
    package enum ChannelError: Error, Sendable {
        case streamReset(UInt32)
        case goneAway
        case severed
    }

    private let transport: ByteChannel
    private var nextMessageID: UInt64 = 0
    private var inbound: [UInt8] = []
    // An async mutex serialising whole exchanges. Actor isolation alone doesn't:
    // `request` suspends between sending and reading its reply, so a reentrant
    // exchange could send a second request and consume the first one's reply.
    // Each exchange holds this from its first send through its reply, so a reply
    // can never be misattributed.
    private var exchangeBusy = false
    private var exchangeWaiters: [CheckedContinuation<Void, Never>] = []

    init(host: String, port: UInt16, readTimeout: TimeInterval = 5) {
        self.transport = ByteChannel(host: host, port: port, readTimeout: readTimeout)
    }

    func connect(timeout: TimeInterval = 4) async throws {
        try await transport.connect(timeout: timeout)
        try await performHandshake()
    }

    /// Close the underlying transport. Safe to call from any isolation.
    package nonisolated func close() {
        transport.close()
    }

    // MARK: Exchanges

    /// Send a payload and return the decoded reply.
    package func request(_ payload: DeviceObject) async throws -> DeviceObject {
        try await withExchangeLock {
            try await self.sendEnvelope(payload, awaitingReply: true)
            return try await self.readReply()
        }
    }

    /// Send a fire-and-forget payload with no reply. The report path streams
    /// many of these over one channel.
    package func emit(_ payload: DeviceObject) async throws {
        try await withExchangeLock {
            try await self.sendEnvelope(payload, awaitingReply: false)
        }
    }

    /// Invoke a CoreDevice feature: wrap `input` in the feature envelope, send
    /// it, and return the unwrapped result.
    package func invoke(
        _ selector: String,
        input: DeviceObject = .fields([]),
        action: String? = nil
    ) async throws -> DeviceObject {
        let envelope = CoreDeviceEnvelope.request(selector: selector, input: input, action: action)
        let reply = try await withExchangeLock {
            try await self.sendEnvelope(envelope, awaitingReply: true)
            return try await self.readReply()
        }
        return try CoreDeviceEnvelope.output(from: reply)
    }

    /// Ask the endpoint to describe itself: announce with messaging protocol
    /// version 7 and read the pushed service directory (`Services`: name → port)
    /// plus device `Properties`. Only the directory endpoint answers this with a
    /// services map; a plain service port times out instead.
    func requestServiceDirectory() async throws -> DeviceObject {
        let announce: DeviceObject = .object([
            ("MessageType", .text("Handshake")),
            ("MessagingProtocolVersion", .unsigned(7)),
            ("UUID", .identifier(UUID())),
            ("Properties", .object([
                ("RemoteXPCVersionFlags", .unsigned(0x0100_0000_0000_0006)),
                ("SensitivePropertiesVisible", .flag(true))
            ])),
            ("Services", .fields([]))
        ])
        return try await withExchangeLock {
            try await self.sendEnvelope(announce, awaitingReply: false)
            return try await self.readReply()
        }
    }

    /// Frame one payload and send it, advancing the message id. Not serialised
    /// itself; callers run it inside `withExchangeLock`.
    private func sendEnvelope(_ payload: DeviceObject, awaitingReply: Bool) async throws {
        let envelope = ObjectCoder.encodeEnvelope(payload, messageID: nextMessageID, awaitingReply: awaitingReply)
        try await transport.send(FrameTransport.data(streamID: SessionHandshake.rootStream, envelope))
        nextMessageID += 1
    }

    /// Run `body` with exclusive access to the channel, so no other exchange can
    /// interleave between its send and its reply.
    private func withExchangeLock<Value: Sendable>(
        _ body: () async throws -> Value
    ) async rethrows -> Value {
        if exchangeBusy {
            await withCheckedContinuation { exchangeWaiters.append($0) }
        } else {
            exchangeBusy = true
        }
        defer {
            if exchangeWaiters.isEmpty {
                exchangeBusy = false
            } else {
                exchangeWaiters.removeFirst().resume() // hand the lock to the next waiter
            }
        }
        return try await body()
    }

    // MARK: Handshake

    private func performHandshake() async throws {
        var handshake = SessionHandshake()
        for block in handshake.openingBlocks() {
            try await transport.send(block)
        }
        nextMessageID += 1
        try handshake.acceptPeerFrame(try await readFrameHeader())
        try await transport.send(FrameTransport.settingsAcknowledge())
    }

    // MARK: Receive

    /// Accumulate DATA payloads until a non-empty reply envelope decodes,
    /// carving individual envelopes out of split or coalesced frames.
    private func readReply() async throws -> DeviceObject {
        while true {
            inbound += try await readDataPayload()
            while let length = try ObjectCoder.envelopeByteCount(in: inbound) {
                let envelope = Array(inbound.prefix(length))
                inbound.removeFirst(length)
                if let object = try ObjectCoder.decodeEnvelope(envelope), object.carriesFields {
                    return object // skip empty keep-alive envelopes
                }
            }
        }
    }

    /// Read frames until a DATA frame arrives, returning its payload; drop
    /// SETTINGS / WINDOW_UPDATE / PING / HEADERS; fail on RST_STREAM / GOAWAY.
    private func readDataPayload() async throws -> [UInt8] {
        while true {
            let header = FrameTransport.parseHeader(try await transport.readExactly(FrameTransport.headerLength))
            let body = header.length > 0 ? try await transport.readExactly(header.length) : []
            switch header.kind {
            case .data:
                return body

            case .resetStream:
                throw ChannelError.streamReset(header.streamID)

            case .goAway:
                throw ChannelError.goneAway

            default:
                continue
            }
        }
    }

    /// Read one full frame, discard its body, and return its header.
    private func readFrameHeader() async throws -> FrameTransport.Header {
        let header = FrameTransport.parseHeader(try await transport.readExactly(FrameTransport.headerLength))
        if header.length > 0 { _ = try await transport.readExactly(header.length) }
        return header
    }
}
