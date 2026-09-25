// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// A synchronous CLI wait owns this socket and drains it between roster reads.
/// No worker or timer outlives the wait, and socket close revokes its demand.
final class UDSSurfaceObservation: CLISurfaceObservation {
    private var fd: Int32
    private let paneId: String
    private var buffer = Data()
    private var sequence: UInt64?

    init(fd: Int32, paneId: String) {
        self.fd = fd
        self.paneId = paneId
    }

    deinit { close() }

    static func connect(
        paneId: String,
        credentials: (sessionId: String, cap: String),
        timeoutSeconds: Double
    ) throws -> UDSSurfaceObservation {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var attempt = 0
        while true {
            guard deadline.timeIntervalSinceNow > 0 else {
                throw CLIError.transportTimeout("timed out subscribing to pane frames")
            }
            let fd: Int32
            do {
                fd = try UDSClientSocket.connect(to: daemonSocketPath())
            } catch {
                throw CLIError.transportUnavailable("cannot connect to daemon: \(error)")
            }
            let observation = UDSSurfaceObservation(fd: fd, paneId: paneId)
            do {
                try authenticateConnection(
                    fd: fd, sessionId: credentials.sessionId, cap: credentials.cap, deadline: deadline
                )
                let params = try JSONSerialization.data(withJSONObject: ["paneId": paneId, "frames": true])
                let request = RPCEnvelope(
                    id: 1, type: .request, method: RPCMethod.paneSubscribe.rawValue, body: .params(params)
                )
                try UDSClientSocket.writeAll(fd: fd, data: RPCFraming.encode(request.encode()))
                try observation.readAcknowledgement(deadline: deadline)
                return observation
            } catch let CLIError.daemon(code, _, _) where code == notReadyCode && attempt < 10 {
                observation.close()
                attempt += 1
                let remaining = deadline.timeIntervalSinceNow
                if remaining > 0 { Thread.sleep(forTimeInterval: min(remaining, 0.1)) }
            } catch {
                observation.close()
                throw error
            }
        }
    }

    func close() {
        guard fd >= 0 else { return }
        UDSClientSocket.close(fd)
        fd = -1
    }

    func readAcknowledgement(deadline: Date) throws {
        while true {
            if let envelope = try nextEnvelope() {
                guard envelope.id == 1, envelope.type == .response else {
                    throw CLIError.invalidResponse("expected pane subscription acknowledgement")
                }
                if case let .error(error) = envelope.body {
                    throw CLIError.daemon(code: error.code, message: error.message, details: error.details)
                }
                guard case let .result(data) = envelope.body,
                    try JSONDecoder().decode(PaneSubscribeAck.self, from: data).success else {
                    throw CLIError.invalidResponse("invalid pane subscription acknowledgement")
                }
                return
            }
            guard UDSClientSocket.waitReadable(fd: fd, deadline: deadline) else {
                throw CLIError.transportTimeout("timed out subscribing to pane frames")
            }
            try readAvailable()
        }
    }

    func latestSequence() throws -> UInt64? {
        try readAvailable()
        while let envelope = try nextEnvelope() {
            guard envelope.id == 1, envelope.type == .event, case let .params(data) = envelope.body else {
                throw CLIError.invalidResponse("invalid pane subscription event")
            }
            switch envelope.method.flatMap(PaneEventName.init(rawValue:)) {
            case .surfaceChanged:
                let event = try JSONDecoder().decode(SurfaceChangedEvent.self, from: data)
                guard event.paneId == paneId else {
                    throw CLIError.invalidResponse("surface event names another pane")
                }
                sequence = event.sequence

            case .stateChanged:
                let event = try JSONDecoder().decode(StateChangedEvent.self, from: data)
                if event.state == .shutdown || event.state == .failed {
                    throw CLIError.paneUnavailable("pane stopped rendering while waiting for its surface")
                }

            case .orientationChanged:
                break

            case nil:
                throw CLIError.invalidResponse("unknown pane subscription event")
            }
        }
        return sequence
    }

    private func readAvailable() throws {
        guard fd >= 0 else { throw CLIError.transportInterrupted("surface subscription is closed") }
        let chunk: Data?
        do {
            chunk = try UDSClientSocket.readAvailable(fd: fd)
        } catch {
            throw CLIError.transportInterrupted("surface subscription read failed: \(error)")
        }
        guard let chunk else {
            throw CLIError.transportInterrupted("daemon closed the surface subscription")
        }
        buffer.append(chunk)
    }

    private func nextEnvelope() throws -> RPCEnvelope? {
        guard let (payload, consumed) = try RPCFraming.decodeNext(from: buffer) else { return nil }
        buffer.removeFirst(consumed)
        return try RPCEnvelope.decode(payload)
    }
}
