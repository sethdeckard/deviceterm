// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
#if canImport(Darwin)
import Darwin
#endif

// The round-trip path below is one request → one response: it frames an
// `RPCEnvelope`, sends it over the UDS, and reads framed bytes until a full
// response envelope decodes (or a bounded timeout elapses). It returns the
// response body `Data` for `.result`, or throws `CLIError` on `.error` /
// transport failure.
/// Read one framed response envelope from `fd`, blocking until a
/// full frame arrives or `deadline` passes. Extracted from `roundTrip`
/// so the auto-auth handshake can reuse the read path.
private func readOneEnvelope(
    fd: Int32,
    deadline: Date
) throws -> RPCEnvelope {
    var buffer = Data()
    while true {
        do {
            if let (payload, _) = try RPCFraming.decodeNext(from: buffer) {
                do {
                    return try RPCEnvelope.decode(payload)
                } catch {
                    throw CLIError.invalidResponse("invalid daemon response: \(error)")
                }
            }
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.invalidResponse("invalid daemon response frame: \(error)")
        }
        guard UDSClientSocket.waitReadable(fd: fd, deadline: deadline) else {
            throw CLIError.transportTimeout("timed out waiting for daemon response")
        }
        let chunk: Data?
        do {
            chunk = try UDSClientSocket.readAvailable(fd: fd)
        } catch {
            throw CLIError.transportInterrupted("read failed: \(error)")
        }
        guard let chunk else {
            throw CLIError.transportInterrupted("daemon closed the connection")
        }
        buffer.append(chunk)
    }
}

/// Send `session.authenticate` over `fd` using the tab's env creds.
/// Returns silently on success. On auth failure, throws so the
/// caller surfaces the error rather than silently proceeding with a
/// connection the daemon won't honor for session-scoped methods.
func authenticateConnection(
    fd: Int32,
    sessionId: String,
    cap: String,
    deadline: Date
) throws {
    let params = SessionAuthenticateParams(sessionId: sessionId, cap: cap)
    let envelope = RPCEnvelope(
        id: 0,
        type: .request,
        method: RPCMethod.sessionAuthenticate.rawValue,
        body: .params(try JSONEncoder().encode(params))
    )
    let frame = try RPCFraming.encode(envelope.encode())
    do {
        try UDSClientSocket.writeAll(fd: fd, data: frame)
    } catch {
        throw CLIError.transportInterrupted("auth write failed: \(error)")
    }
    let response = try readOneEnvelope(
        fd: fd,
        deadline: deadline
    )
    if case let .error(err) = response.body {
        throw CLIError.daemon(
            code: err.code,
            message: err.message,
            details: err.details
        )
    }
}

/// The daemon's "provenance not ready" code: session provenance or readiness
/// cannot yet be established, typically because terminal binding or
/// fresh-daemon restoration is incomplete (the GUI normally binds within a
/// round-trip of the tab opening; a daemon or GUI restart briefly re-opens the
/// window). It is retryable, distinct from a hard auth failure (`-32001`),
/// which is terminal. Kept as a literal because the CLI links `DaemonProtocol`,
/// not the daemon's `RPCMethodError`.
let notReadyCode = -32_002

/// Connect, authenticate, and round-trip one request under one deadline,
/// retrying only the daemon's provenance-not-ready response. Authentication,
/// the command response, and readiness retry delays all spend
/// `timeoutSeconds`; no phase restarts the deadline. Each retry uses a fresh
/// connection, while hard authentication and other failures return
/// immediately.
func roundTrip(
    method: String,
    params: Data?,
    timeoutSeconds: Double = AppCommandDeadline.cliRequestTimeoutSeconds
) throws -> Data {
    try roundTrip(timeoutSeconds: timeoutSeconds) { (method, params) }
}

/// Connect, perform any env-credential authentication, then build the request.
/// A readiness retry reconnects and invokes the builder again, allowing
/// deadline-sensitive payloads to recalculate against their captured deadline.
func roundTrip(
    timeoutSeconds: Double,
    buildingRequest: () throws -> (method: String, params: Data?)
) throws -> Data {
    let maxNotReadyRetries = 10
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    var attempt = 0
    while true {
        guard deadline.timeIntervalSinceNow > 0 else {
            throw CLIError.transportTimeout("timed out waiting for daemon response")
        }
        do {
            return try roundTripOnce(deadline: deadline, buildingRequest: buildingRequest)
        } catch let CLIError.daemon(code, message, details) {
            guard code == notReadyCode, attempt < maxNotReadyRetries else {
                throw CLIError.daemon(
                    code: code,
                    message: message,
                    details: details
                )
            }
            attempt += 1
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw CLIError.transportTimeout("timed out waiting for daemon readiness")
            }
            usleep(useconds_t(max(1, min(remaining, 0.1) * 1_000_000)))
        }
    }
}

private func roundTripOnce(
    deadline: Date,
    buildingRequest: () throws -> (method: String, params: Data?)
) throws -> Data {
    let path = daemonSocketPath()
    let fd: Int32
    do {
        fd = try UDSClientSocket.connect(to: path)
    } catch {
        throw CLIError.transportUnavailable("cannot connect to daemon at \(path): \(error)")
    }
    defer { UDSClientSocket.close(fd) }

    // Auto-auth when env carries tab creds. The daemon's dispatcher
    // requires every connection that wants .session-scoped methods
    // to have authenticated; pre-sending the auth handshake keeps
    // the CLI's per-call shape unchanged. Out-of-tab callers (no
    // env) skip this and only succeed against daemon-wide methods.
    if let session = envValue(DeviceTermEnv.session), !session.isEmpty,
        let cap = envValue(DeviceTermEnv.sessionCap), !cap.isEmpty {
        try authenticateConnection(
            fd: fd,
            sessionId: session,
            cap: cap,
            deadline: deadline
        )
    }

    guard deadline.timeIntervalSinceNow > 0 else {
        throw CLIError.transportTimeout("timed out waiting for daemon response")
    }

    let request = try buildingRequest()
    let body: RPCEnvelope.Body = request.params.map { .params($0) } ?? .empty
    let envelope = RPCEnvelope(id: 1, type: .request, method: request.method, body: body)
    let frame: Data
    do {
        frame = try RPCFraming.encode(envelope.encode())
    } catch {
        throw CLIError.classified(code: .internalError, message: "encode failed: \(error)")
    }
    do {
        try UDSClientSocket.writeAll(fd: fd, data: frame)
    } catch {
        throw CLIError.transportInterrupted("write failed: \(error)")
    }

    let response = try readOneEnvelope(
        fd: fd,
        deadline: deadline
    )
    switch response.body {
    case let .result(data):
        return data

    case .empty:
        return Data()

    case let .error(err):
        throw CLIError.daemon(
            code: err.code,
            message: err.message,
            details: err.details
        )

    case .params:
        throw CLIError.invalidResponse("unexpected params body on a response")
    }
}

// MARK: - Pane resolution

/// Extract the params payload from a built request envelope, for handing
/// to `roundTrip(method:params:)`.
func paramsData(_ envelope: RPCEnvelope) -> Data? {
    if case let .params(data) = envelope.body { return data }
    return nil
}

/// Response timeout for a gesture RPC that the daemon answers only after
/// the gesture finishes dispatching: the gesture's own wall-clock plus
/// generous headroom for the sim's synchronous per-contact HID sends.
///
/// Takes the phases separately and bounds each one, because that is how the
/// daemon validates them: `swipe` runs a motion *and* a dwell, each accepted
/// up to `GestureDuration.maxMs` on its own, so a legal swipe can outlast that
/// ceiling and a deadline capped at it would expire mid-gesture.
///
/// Bounding is per phase rather than on the total because the values reaching
/// here are unvalidated: argv takes any `Int` and the daemon refuses anything
/// past the ceiling with `invalidParams`. Summing raw ones could overflow, and
/// deriving a deadline from a value the daemon will reject would leave the CLI
/// waiting days on a peer that stalled instead of answering.
func gestureTimeout(_ phasesMs: Int...) -> Double {
    let total = phasesMs.reduce(0) { $0 + min(max(0, $1), GestureDuration.maxMs) }
    return 5 + Double(total) / 1_000.0 + 5
}

/// Send a request envelope built by `CLICommands` and return the result
/// payload. The builders always set `method`; a nil here is a bug.
func send(
    _ envelope: RPCEnvelope,
    timeoutSeconds: Double = AppCommandDeadline.cliRequestTimeoutSeconds
) throws -> Data {
    guard let method = envelope.method else {
        throw CLIError.classified(
            code: .internalError,
            message: "internal error: request envelope has no method"
        )
    }
    return try roundTrip(
        method: method,
        params: paramsData(envelope),
        timeoutSeconds: timeoutSeconds
    )
}

/// Query `daemon.capabilities` against the running daemon. Returns
/// the response on success, nil if the daemon is unreachable or the
/// reply doesn't decode. Pure I/O; the caller decides what to render
/// when the daemon is down (typically: the no-session fallback view).
func fetchDaemonCapabilities() -> DaemonCapabilitiesResponse? {
    // No payload creds; `roundTrip` authenticates the connection from env,
    // and `daemon.capabilities` derives authority from that connection, not
    // the request body.
    guard let result = try? roundTrip(
        method: RPCMethod.daemonCapabilities.rawValue,
        params: nil,
        timeoutSeconds: 2
    ) else {
        return nil
    }
    return try? JSONDecoder().decode(
        DaemonCapabilitiesResponse.self,
        from: result
    )
}

// MARK: - Meta / special verb helpers
//
// The doc-dump and diagnostic verbs (help, agents, doctor, version,
// dump-config, completions) return a CommandOutcome the driver
// renders. The streaming (`events`) and exec (`with-pane`) verbs own
// their I/O and terminate the process directly (`-> Never`).
