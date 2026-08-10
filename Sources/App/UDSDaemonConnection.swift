// SPDX-License-Identifier: GPL-3.0-or-later
//
// UDSDaemonConnection: legacy Unix-domain-socket transport for the
// GUI, retained as a smoke-mode-only fallback.
//
// Production GUI talks to the daemon via XPC (`XPCDaemonConnection`).
// The `make verify` GUI smoke gate, however, runs hermetically without
// launchd-vended mach services: there's no SMAppService registration
// in the smoke harness, so the XPC connection would hang trying to
// reach a mach service that doesn't exist. To keep the smoke gate
// useful, the GUI under `--smoke` detects the
// `DEVICETERM_DAEMON_SOCK` env var and routes through this class
// instead: it spawns the daemon binary via `Process()` and connects
// to the resulting UDS. Production XPC remains the only transport
// reachable from a normally-launched bundle.
//
// This is a deliberate, narrowly-scoped exception to the "no
// fallback" rule: the path is only taken under the
// `--smoke` argv (which the production app never carries), and the
// daemon binary it spawns is the same one launchd would normally
// vend.

import DaemonProtocol
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The socket connection. `@unchecked Sendable`: every mutable
/// member is touched only on `queue` (serial), which is the
/// synchronization domain. Continuations are resumed from that
/// queue.
final class UDSDaemonConnection: DaemonRequestTransport, @unchecked Sendable {
    private let queue = DispatchQueue(label: "deviceterm.daemonclient.uds.io")
    private var fd: Int32
    private var readBuffer = Data()
    private var pending: [UInt32: CheckedContinuation<Data, Error>] = [:]
    /// Active subscriptions. The same id used for the initial
    /// `pane.subscribe` request also tags every later `evt` frame
    /// from the daemon.
    private var subscriptions: [UInt32: AsyncStream<(String, Data)>.Continuation] = [:]
    private var nextId: UInt32 = 1
    private var readSource: DispatchSourceRead?
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.handleReadable() }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            UDSClientSocket.close(self.fd)
        }
        self.readSource = source
        source.resume()
    }

    func request(method: String, params: Data?) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [weak self] in
                guard let self, !self.closed else {
                    cont.resume(throwing: DaemonClientError.transport("connection closed"))
                    return
                }
                let id = self.nextId
                self.nextId &+= 1
                let body: RPCEnvelope.Body = params.map { .params($0) } ?? .empty
                let env = RPCEnvelope(id: id, type: .request, method: method, body: body)
                let frame: Data
                do {
                    frame = try RPCFraming.encode(env.encode())
                } catch {
                    cont.resume(throwing: DaemonClientError.transport("encode: \(error)"))
                    return
                }
                self.pending[id] = cont
                do {
                    try UDSClientSocket.writeAll(fd: self.fd, data: frame)
                } catch {
                    self.pending.removeValue(forKey: id)
                    cont.resume(throwing: DaemonClientError.transport("write: \(error)"))
                }
            }
        }
    }

    /// Subscribe to a long-lived event stream. Returns the initial
    /// ack plus the AsyncStream of subsequent evt frames as raw
    /// (method, params) pairs.
    func subscribe(
        method: String,
        params: Data?
    ) async throws -> (initial: Data, events: AsyncStream<(String, Data)>) {
        let (stream, cont) = AsyncStream.makeStream(of: (String, Data).self)
        let initial: Data = try await withCheckedThrowingContinuation { ready in
            queue.async { [weak self] in
                guard let self, !self.closed else {
                    ready.resume(throwing: DaemonClientError.transport("connection closed"))
                    cont.finish()
                    return
                }
                let id = self.nextId
                self.nextId &+= 1
                let body: RPCEnvelope.Body = params.map { .params($0) } ?? .empty
                let env = RPCEnvelope(id: id, type: .request, method: method, body: body)
                let frame: Data
                do {
                    frame = try RPCFraming.encode(env.encode())
                } catch {
                    cont.finish()
                    ready.resume(throwing: DaemonClientError.transport("encode: \(error)"))
                    return
                }
                self.pending[id] = ready
                self.subscriptions[id] = cont
                do {
                    try UDSClientSocket.writeAll(fd: self.fd, data: frame)
                } catch {
                    self.pending.removeValue(forKey: id)
                    self.subscriptions.removeValue(forKey: id)
                    cont.finish()
                    ready.resume(throwing: DaemonClientError.transport("write: \(error)"))
                }
            }
        }
        return (initial, stream)
    }

    func close() {
        queue.async { [weak self] in
            self?.failAll(DaemonClientError.transport("connection closed by client"))
        }
    }

    private func handleReadable() {
        let chunk: Data?
        do {
            chunk = try UDSClientSocket.readAvailable(fd: fd)
        } catch {
            failAll(DaemonClientError.transport("read: \(error)"))
            return
        }
        guard let chunk else {
            failAll(DaemonClientError.transport("daemon closed the connection"))
            return
        }
        if chunk.isEmpty { return }
        readBuffer.append(chunk)
        while let (payload, consumed) = try? RPCFraming.decodeNext(from: readBuffer) {
            readBuffer.removeFirst(consumed)
            guard let env = try? RPCEnvelope.decode(payload) else { continue }
            // Responses and events always carry the request id they
            // correlate to; a frame without one isn't part of the
            // inbound contract.
            guard let envId = env.id else { continue }
            switch env.type {
            case .response:
                guard let cont = pending.removeValue(forKey: envId) else { continue }
                switch env.body {
                case let .result(data):
                    cont.resume(returning: data)

                case .empty:
                    cont.resume(returning: Data())

                case let .error(err):
                    subscriptions.removeValue(forKey: envId)?.finish()
                    cont.resume(
                        throwing: DaemonClientError.daemon(
                            code: err.code,
                            message: err.message
                        )
                    )

                case .params:
                    subscriptions.removeValue(forKey: envId)?.finish()
                    cont.resume(
                        throwing: DaemonClientError.transport(
                            "unexpected params on response"
                        )
                    )
                }

            case .event:
                guard let sink = subscriptions[envId] else { break }
                guard case let .params(data) = env.body else { break }
                sink.yield((env.method ?? "", data))

            case .request:
                break
            }
        }
    }

    private func failAll(_ error: Error) {
        if closed { return }
        closed = true
        let waiters = pending
        pending.removeAll()
        for (_, cont) in waiters { cont.resume(throwing: error) }
        let sinks = subscriptions
        subscriptions.removeAll()
        for (_, sink) in sinks { sink.finish() }
        readSource?.cancel()
        readSource = nil
    }
}

@MainActor
enum UDSDaemonBringup {
    /// Spawn the daemon binary if no UDS at `socketPath` accepts, then
    /// poll-connect with backoff. Returns a wrapped connection.
    static func bringUp(socketPath: String) async throws -> UDSDaemonConnection {
        if let fd = tryConnect(socketPath) {
            return UDSDaemonConnection(fd: fd)
        }
        guard let binary = daemonBinaryPath() else {
            throw DaemonClientError.transport(
                "smoke fallback: could not locate deviceterm-daemon binary"
            )
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        do {
            try proc.run()
        } catch {
            throw DaemonClientError.transport("smoke fallback spawn: \(error)")
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let fd = tryConnect(socketPath) {
                return UDSDaemonConnection(fd: fd)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw DaemonClientError.transport("smoke fallback: timed out connecting at \(socketPath)")
    }

    private static func tryConnect(_ path: String) -> Int32? {
        try? UDSClientSocket.connect(to: path)
    }

    /// Smoke-mode daemon discovery. Honors `DEVICETERM_DAEMON_PATH`
    /// override; otherwise looks inside the .app bundle.
    private static func daemonBinaryPath() -> String? {
        if let env = ProcessInfo.processInfo.environment[DeviceTermEnv.daemonPath],
            !env.isEmpty {
            return env
        }
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath()
        if let exe, exe.path.contains(".app/") {
            let appRoot = exe
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let helper = appRoot
                .appendingPathComponent(
                    "Contents/Library/LoginItems/deviceterm-daemon.app"
                    + "/Contents/MacOS/deviceterm-daemon"
                )
            if FileManager.default.isExecutableFile(atPath: helper.path) {
                return helper.path
            }
        }
        return SessionEnvironment.locateSibling(named: "deviceterm-daemon")
    }
}
