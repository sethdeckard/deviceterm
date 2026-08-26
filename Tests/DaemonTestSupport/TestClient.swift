// SPDX-License-Identifier: GPL-3.0-or-later

import Daemon
import Foundation

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Client harness

/// Minimal blocking UDS client purpose-built for these tests: connect,
/// write a framed envelope, then block-read until a full response frame
/// is back.
///
/// Production GUI/CLI clients have their own nicer wrappers; this harness
/// deliberately stays tiny so the integration tests exercise the wire and
/// not test infrastructure.
///
/// Uses only public Daemon API so it can live in a plain library shared
/// by every test target.
public final class TestClient {
    public let fd: Int32
    /// Held across `receive` calls so partial reads between frame
    /// boundaries don't lose bytes: streaming-event tests pull
    /// many frames off one connection so the buffer has to persist.
    private var buffer = Data()

    private init(fd: Int32) {
        self.fd = fd
    }

    public static func connect(to path: String) throws -> TestClient {
        let fd = try UDSSocket.connectClient(to: path)
        return TestClient(fd: fd)
    }

    /// Connect + send a `session.authenticate` handshake for a freshly
    /// minted session, returning a client bound to it for its lifetime.
    /// Takes the `CreatedSession` because the one-time bearer capability
    /// lives there (never on `SessionState`). The daemon keeps only the
    /// verifier. Subsequent calls can invoke `.session`-scoped methods
    /// without per-call cred threading.
    public static func connectAuthenticated(
        to path: String,
        as created: CreatedSession
    ) throws -> TestClient {
        try connectAuthenticated(
            to: path,
            sessionId: created.state.id.uuidString,
            cap: created.capability.token
        )
    }

    /// Primitive handshake against an explicit `(sessionId, cap)`: used by
    /// tests that deliberately present creds that won't validate (stale /
    /// wrong cap), which have no `CreatedSession`. Throws
    /// `TestClientError.authFailed` on rejection.
    public static func connectAuthenticated(
        to path: String,
        sessionId: String,
        cap: String
    ) throws -> TestClient {
        let client = try TestClient.connect(to: path)
        let params = SessionAuthenticateParams(sessionId: sessionId, cap: cap)
        let envelope = RPCEnvelope(
            id: 0,
            type: .request,
            method: RPCMethod.sessionAuthenticate.rawValue,
            body: .params(try JSONEncoder().encode(params))
        )
        try client.send(envelope)
        let response = try client.receive()
        guard case .result = response.body else {
            client.close()
            throw TestClientError.authFailed
        }
        return client
    }

    public func close() {
        Darwin.close(fd)
    }

    /// Send one framed envelope. Synchronous.
    public func send(_ envelope: RPCEnvelope) throws {
        let bytes = try envelope.encode()
        let frame = RPCFraming.encode(bytes)
        try UDSSocket.writeAll(fd: fd, data: frame)
    }

    /// Block until exactly one framed envelope has been received.
    /// Times out after `seconds` to keep failing tests from hanging
    /// the suite.
    public func receive(timeoutSeconds: Double = 2) throws -> RPCEnvelope {
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        while Date() < deadline {
            if let frame = try RPCFraming.decodeNext(from: buffer) {
                let end = buffer.index(buffer.startIndex, offsetBy: frame.consumed)
                buffer = Data(buffer[end..<buffer.endIndex])
                return try RPCEnvelope.decode(frame.payload)
            }
            if let chunk = try UDSSocket.readAvailable(fd: fd), !chunk.isEmpty {
                buffer.append(chunk)
                continue
            }
            // No data right now. Sleep briefly and retry.
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw TestClientError.timedOutWaitingForFrame
    }
}

public enum TestClientError: Error, Equatable {
    case timedOutWaitingForFrame
    /// `session.authenticate` rejected the connection's auth
    /// attempt. The (sessionId, cap) pair didn't validate against
    /// the daemon's `SessionManager`.
    case authFailed
}
