// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// The client half. Connect to the resident harness,
/// send one framed request, read one framed reply.
///
/// Reuses `DaemonProtocol`'s Foundation-only `UDSClientSocket` (non-
/// blocking connect + read/write) and `RPCFraming`. Because the fd is
/// non-blocking, the read side polls `readAvailable` and accumulates
/// until `RPCFraming.decodeNext` yields a full frame or the deadline
/// passes.
enum UITestClient {
    struct Reply {
        /// The raw reply JSON, printed verbatim by the caller.
        let json: Data
        /// The reply's `ok` field, which drives the process exit code.
        let ok: Bool
    }

    static let standardReplyTimeout: TimeInterval = 5
    static let axDumpReplyTimeout: TimeInterval = 15

    static func send(
        _ request: UITestRequest,
        socketPath: String,
        timeout requestedTimeout: TimeInterval? = nil
    ) throws -> Reply {
        let timeout = requestedTimeout ?? replyTimeout(for: request)
        let fd: Int32
        do {
            fd = try UDSClientSocket.connect(to: socketPath)
        } catch {
            throw UITestClientError.notRunning(path: socketPath)
        }
        defer { UDSClientSocket.close(fd) }

        let body = try JSONEncoder().encode(request)
        try UDSClientSocket.writeAll(fd: fd, data: RPCFraming.encode(body))

        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let chunk = try UDSClientSocket.readAvailable(fd: fd) else {
                throw UITestClientError.connectionClosed
            }
            if !chunk.isEmpty {
                buffer.append(chunk)
                if let frame = try RPCFraming.decodeNext(from: buffer) {
                    return Reply(json: frame.payload, ok: replyIsOK(frame.payload))
                }
            }
            usleep(2_000)
        }
        throw UITestClientError.replyTimedOut(seconds: timeout)
    }

    static func replyTimeout(for request: UITestRequest) -> TimeInterval {
        request.method == .axDump ? axDumpReplyTimeout : standardReplyTimeout
    }

    private static func replyIsOK(_ json: Data) -> Bool {
        guard
            let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let ok = object["ok"] as? Bool
        else { return false }
        return ok
    }
}
