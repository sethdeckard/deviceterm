// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The Unix-domain-socket transport for the GUI, reached only in smoke mode.
///
/// `@unchecked Sendable`: every mutable member is touched only on `queue`
/// (serial), which is the synchronization domain. Continuations are resumed
/// from that queue.
///
/// The production GUI talks to the daemon via XPC (`XPCDaemonConnection`).
/// The `make verify` GUI smoke gate, however, runs hermetically without
/// launchd-vended mach services: there's no SMAppService registration
/// in the smoke harness, so the XPC connection would hang trying to
/// reach a mach service that doesn't exist. To keep the smoke gate
/// useful, the GUI under `--smoke` detects the
/// `DEVICETERM_DAEMON_SOCK` env var and routes through this class
/// instead: it spawns the daemon binary via `Process()` and connects
/// to the resulting UDS. Production XPC remains the only transport
/// reachable from a normally-launched bundle.
///
/// This is a deliberate, narrowly-scoped exception to the "no
/// fallback" rule: the path is only taken under the
/// `--smoke` argv (which the production app never carries), and the
/// daemon binary it spawns is the same one launchd would normally
/// vend.
final class UDSDaemonConnection: DaemonRequestTransport, @unchecked Sendable {
    /// One parked call's cancellation state. The send and the cancellation
    /// handler both hop onto `queue` before touching it, so the serial queue
    /// is its synchronization domain, the same invariant every other mutable
    /// member of this class has. Which of the two runs first is unordered,
    /// hence both fields: a cancel that arrives before the send finds no `id`
    /// and leaves `cancelled` for the send to refuse on, and a cancel that
    /// arrives after finds the `id` and resumes the parked continuation.
    private final class CallTicket: @unchecked Sendable {
        var id: UInt32?
        var cancelled = false
    }

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

    /// Round-trip a one-shot request.
    ///
    /// Cancellation-aware: the continuation is otherwise only resumed by a
    /// matching reply, so a request a live-but-silent daemon never answers
    /// would park forever and no external deadline could bound it. On
    /// cancellation the pending entry is dropped and the continuation resumes
    /// once with `CancellationError`, the same contract
    /// `XPCDaemonConnection.requestReturningGeneration` implements.
    func request(method: String, params: Data?) async throws -> Data {
        let queue = queue
        let ticket = CallTicket()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                queue.async { [weak self] in
                    guard let self, !self.closed else {
                        cont.resume(throwing: DaemonClientError.transport("connection closed"))
                        return
                    }
                    // Cancelled before the send reached the queue: don't write
                    // a request nobody is waiting for.
                    if ticket.cancelled {
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    let id = self.nextId
                    self.nextId &+= 1
                    ticket.id = id
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
        } onCancel: {
            queue.async { [weak self] in
                ticket.cancelled = true
                guard let id = ticket.id else { return }
                // Removing the entry is what makes this resume-once: a reply
                // (or `failAll`) arriving afterwards finds nothing to resume.
                self?.pending.removeValue(forKey: id)?
                    .resume(throwing: CancellationError())
            }
        }
    }

    /// Subscribe to a long-lived event stream. Returns the initial
    /// ack plus the AsyncStream of subsequent evt frames as raw
    /// (method, params) pairs.
    ///
    /// The subscribe handshake parks on the same `pending` map a request
    /// does, so it gets the same cancellation contract: cancelling drops the
    /// pending entry, finishes the event stream, and resumes once with
    /// `CancellationError`. Unlike XPC there is no drain notification to send:
    /// the daemon's UDS subscription is torn down when the connection closes,
    /// so a cancelled handshake can leave one live on an open connection until
    /// then.
    func subscribe(
        method: String,
        params: Data?
    ) async throws -> (initial: Data, events: AsyncStream<(String, Data)>) {
        let queue = queue
        let ticket = CallTicket()
        let (stream, cont) = AsyncStream.makeStream(of: (String, Data).self)
        let initial: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { ready in
                queue.async { [weak self] in
                    guard let self, !self.closed else {
                        ready.resume(throwing: DaemonClientError.transport("connection closed"))
                        cont.finish()
                        return
                    }
                    if ticket.cancelled {
                        ready.resume(throwing: CancellationError())
                        cont.finish()
                        return
                    }
                    let id = self.nextId
                    self.nextId &+= 1
                    ticket.id = id
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
        } onCancel: {
            queue.async { [weak self] in
                ticket.cancelled = true
                guard let id = ticket.id else { return }
                self?.subscriptions.removeValue(forKey: id)?.finish()
                self?.pending.removeValue(forKey: id)?
                    .resume(throwing: CancellationError())
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
