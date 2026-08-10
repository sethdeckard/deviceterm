// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
@preconcurrency import XPC

// Shared XPC test plumbing: the in-process anonymous-pair harness
// used to drive the real `XPCServer` / `XPCConnection` dispatch path
// (frame → envelope → handler → reply) without launchd or a real mach
// service. Shared by the XPC round-trip, surface-drain race, and
// peer-validator cache tests.

/// Wire an anonymous XPC listener + a peer endpoint, returning both.
/// The listener is what the server binds against; the peer is what the
/// test client sends through.
func makeAnonymousPair() -> (xpc_connection_t, xpc_connection_t) {
    let listener = xpc_connection_create(nil, nil)
    let endpoint = xpc_endpoint_create(listener)
    let peer = xpc_connection_create_from_endpoint(endpoint)
    return (listener, peer)
}

/// Wire the test client to push every inbound dictionary into the
/// reply box. Filters out error events (e.g. connection invalidation)
/// so the box only ever sees actual responses.
func setupClient(_ client: xpc_connection_t, replyBox: ReplyBox) {
    xpc_connection_set_event_handler(client) { event in
        if xpc_get_type(event) == XPC_TYPE_DICTIONARY {
            Task { await replyBox.deliver(event) }
        }
    }
    xpc_connection_resume(client)
}

/// One-way send an RPC request (empty body) through the client peer.
func sendRequest(
    envelopeId: UInt32,
    method: String,
    client: xpc_connection_t
) {
    sendEncoded(
        RPCEnvelope(id: envelopeId, type: .request, method: method, body: .empty),
        client: client
    )
}

/// Request send with a params body (the empty-body `sendRequest` above
/// doesn't carry method params).
func sendRequest(
    envelopeId: UInt32,
    method: String,
    params: Data,
    client: xpc_connection_t
) {
    sendEncoded(
        RPCEnvelope(id: envelopeId, type: .request, method: method, body: .params(params)),
        client: client
    )
}

/// One-way notification send: a request-shaped frame with no `id`. The
/// dispatcher runs the handler and replies with nothing.
func sendNotification(
    method: String,
    client: xpc_connection_t,
    params: Data? = nil
) {
    let body: RPCEnvelope.Body = params.map { .params($0) } ?? .empty
    sendEncoded(
        RPCEnvelope(id: nil, type: .request, method: method, body: body),
        client: client
    )
}

/// Encode an envelope into the transport dictionary shape and one-way
/// send it through the client peer.
func sendEncoded(_ envelope: RPCEnvelope, client: xpc_connection_t) {
    guard let payload = try? envelope.encode() else { return }
    let message = xpc_dictionary_create(nil, nil, 0)
    xpc_dictionary_set_string(message, XPCTransportKey.type, XPCTransportKey.rpcValue)
    payload.withUnsafeBytes { rawBuffer in
        if let base = rawBuffer.baseAddress {
            xpc_dictionary_set_data(message, XPCTransportKey.data, base, payload.count)
        }
    }
    xpc_connection_send_message(client, message)
}

/// Pull the `data` field out of the reply dictionary and decode it as a
/// UTF-8 string of the result payload, for assertion convenience.
func decodeResultPayload(reply: xpc_object_t) -> String {
    var length: Int = 0
    guard
        let pointer = xpc_dictionary_get_data(reply, XPCTransportKey.data, &length),
        length > 0
    else {
        return ""
    }
    let buffer = UnsafeBufferPointer(
        start: pointer.assumingMemoryBound(to: UInt8.self),
        count: length
    )
    guard let envelope = try? RPCEnvelope.decode(Data(buffer)) else { return "" }
    if case let .result(bytes) = envelope.body {
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }
    return ""
}

func decodeEnvelope(reply: xpc_object_t) throws -> RPCEnvelope {
    var length: Int = 0
    guard
        let pointer = xpc_dictionary_get_data(reply, XPCTransportKey.data, &length),
        length > 0
    else {
        throw XPCPlumbingError.missingPayload
    }
    let buffer = UnsafeBufferPointer(
        start: pointer.assumingMemoryBound(to: UInt8.self),
        count: length
    )
    return try RPCEnvelope.decode(Data(buffer))
}

enum XPCPlumbingError: Error {
    case missingPayload
}

/// Sendable holder for a value an async handler writes once.
actor StringBox {
    var value: String = ""
    func set(_ value: String) {
        self.value = value
    }
}

/// Sendable holder for a reply message the test client receives via its
/// peer event handler. The test awaits the reply by calling
/// `awaitReply`; `deliver` resumes a pending continuation, or, if the
/// reply arrives before anyone is awaiting, stores it so the next
/// `awaitReply` returns immediately. Because the server's `sendEnvelope`
/// uses one-way `xpc_connection_send_message` (not reply semantics),
/// the test client receives the reply as an ordinary inbound message.
actor ReplyBox {
    private var pending: CheckedContinuation<xpc_object_t, Error>?
    private var stored: xpc_object_t?
    /// Cumulative count of inbound replies delivered: lets a test
    /// assert how many replies arrived by a given point (e.g. none by
    /// the time a teardown completed).
    private(set) var receivedCount = 0

    func deliver(_ object: xpc_object_t) {
        receivedCount += 1
        if let continuation = pending {
            pending = nil
            continuation.resume(returning: object)
            return
        }
        stored = object
    }

    func awaitReply() async throws -> xpc_object_t {
        if let stored {
            self.stored = nil
            return stored
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
        }
    }
}

/// Poll a `@Sendable` predicate until true or the deadline; returns
/// whether it became true. Lets a test wait for positive evidence (a
/// backend call, a subscriber count) instead of asserting a possibly-
/// vacuous initial value.
func poll(
    timeout: TimeInterval = 0.5,
    _ predicate: @Sendable () async -> Bool
) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await predicate() { return true }
        try await Task.sleep(nanoseconds: 3_000_000)
    }
    return await predicate()
}
