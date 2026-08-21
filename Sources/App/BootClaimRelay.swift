// SPDX-License-Identifier: GPL-3.0-or-later
//
// BootClaimRelay: one GUI-owned, terminal-bound socket that accepts simulator
// boot claims from shim descendants without waiting for the daemon.

import DaemonProtocol
import Dispatch
import Foundation
import TerminalProvenance
#if canImport(Darwin)
import Darwin
#endif

enum BootClaimRelayError: Error {
    case socketPathTooLong
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case permissionFailed(Int32)
}

/// Mutable socket and anchor state is confined to `queue`. Accepted claims are
/// handed to the main actor only after their acknowledgement has been written,
/// so daemon or main-actor starvation cannot make the shim lose the attempt.
final class BootClaimRelay: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (String, BootClaimEvidence, UInt64) -> Void

    static let maximumFrameBytes = 16 * 1_024

    let socketPath: String
    private let sessionId: String
    private let handler: Handler
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Bool>()
    private let resolveProvenance: ProvenanceSnapshotResolver
    private var listenerFD: Int32 = -1
    private var source: (any DispatchSourceRead)?
    private var anchor: TerminalAnchorFacts?

    init(
        sessionId: String,
        handler: @escaping Handler,
        resolveProvenance: @escaping ProvenanceSnapshotResolver =
            composedProvenanceSnapshotResolver(peer: defaultPeerIdentityResolver)
    ) {
        self.sessionId = sessionId
        self.handler = handler
        self.resolveProvenance = resolveProvenance
        self.socketPath = "/tmp/deviceterm-boot-\(UUID().uuidString.lowercased()).sock"
        self.queue = DispatchQueue(label: "com.deviceterm.boot-claim-relay.\(sessionId)")
        self.queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        stop()
    }

    func start() throws {
        guard socketPath.utf8.count <= 103 else { throw BootClaimRelayError.socketPathTooLong }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BootClaimRelayError.socketFailed(errno) }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                socketPath.withCString { source in
                    _ = strncpy(destination, source, 104)
                }
            }
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                Darwin.bind(fd, address, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let saved = errno
            Darwin.close(fd)
            throw BootClaimRelayError.bindFailed(saved)
        }
        guard chmod(socketPath, S_IRUSR | S_IWUSR) == 0 else {
            let saved = errno
            _ = unlink(socketPath)
            Darwin.close(fd)
            throw BootClaimRelayError.permissionFailed(saved)
        }
        guard Darwin.listen(fd, 8) == 0 else {
            let saved = errno
            _ = unlink(socketPath)
            Darwin.close(fd)
            throw BootClaimRelayError.listenFailed(saved)
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        listenerFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAvailable() }
        self.source = source
        source.resume()
    }

    func bind(foregroundPid: pid_t, ttyName: String) {
        let facts = DefaultTerminalProbe.derive(foregroundPid: foregroundPid, ttyName: ttyName)
        queue.async { [weak self] in self?.anchor = facts }
    }

    func bindForTesting(_ facts: TerminalAnchorFacts?) {
        queue.sync { anchor = facts }
    }

    func stop() {
        let work = { [self] in
            source?.cancel()
            source = nil
            if listenerFD >= 0 {
                Darwin.close(listenerFD)
                listenerFD = -1
            }
            _ = unlink(socketPath)
        }
        if DispatchQueue.getSpecific(key: queueKey) == true {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    private func acceptAvailable() {
        while true {
            let fd = Darwin.accept(listenerFD, nil, nil)
            if fd < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            handle(fd: fd)
        }
    }

    private func handle(fd: Int32) {
        defer { Darwin.close(fd) }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))
        let status: BootClaimRelayAckStatus
        var acceptedClaim: BootClaimEvidence?
        var acceptedDeadlineNanoseconds: UInt64?
        if let snapshot = resolveProvenance(fd), snapshot.peer.euid == geteuid() {
            switch ProvenanceMatcher.verdict(
                peer: .uds(snapshot.peer, ancestors: snapshot.ancestors),
                sessionOwner: nil,
                anchor: anchor
            ) {
            case .authorized:
                acceptedClaim = readClaim(fd: fd)
                if let acceptedClaim {
                    let duration = acceptedClaim.remainingLeaseMilliseconds
                        .multipliedReportingOverflow(by: 1_000_000)
                    let deadline = DispatchTime.now().uptimeNanoseconds
                        .addingReportingOverflow(duration.partialValue)
                    if !duration.overflow, !deadline.overflow {
                        acceptedDeadlineNanoseconds = deadline.partialValue
                    }
                }
                status = acceptedDeadlineNanoseconds == nil ? .rejected : .accepted

            case .notReady:
                status = .notReady

            case .unauthorized:
                status = .rejected
            }
        } else {
            status = .rejected
        }
        if let data = try? JSONEncoder().encode(BootClaimRelayAck(status: status)) {
            writeAll(fd: fd, data: RPCFraming.encode(data))
        }
        guard let acceptedClaim, let acceptedDeadlineNanoseconds else { return }
        let sessionId = self.sessionId
        let handler = self.handler
        Task { @MainActor in
            handler(sessionId, acceptedClaim, acceptedDeadlineNanoseconds)
        }
    }

    private func readClaim(fd: Int32) -> BootClaimEvidence? {
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        var data = Data()
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let frame = try? RPCFraming.decodeNext(
                from: data,
                cap: Self.maximumFrameBytes
            ) {
                guard let claim = try? JSONDecoder().decode(
                    BootClaimEvidence.self,
                    from: frame.payload
                ), UUID(uuidString: claim.attemptId) != nil,
                    UUID(uuidString: claim.udid) != nil,
                    claim.source == .shim,
                    claim.remainingLeaseMilliseconds > 0,
                    claim.remainingLeaseMilliseconds
                        <= BootClaimEvidence.maximumLeaseMilliseconds else { return nil }
                return claim
            }
            var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = Darwin.poll(&pollDescriptor, 1, 50)
            guard result >= 0 else { return nil }
            if result == 0 { continue }
            var buffer = [UInt8](repeating: 0, count: 4_096)
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { return nil }
            data.append(buffer, count: count)
            if data.count > Self.maximumFrameBytes + 4 { return nil }
        }
        return nil
    }

    private func writeAll(fd: Int32, data: Data) {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let count = Darwin.write(fd, pointer, remaining)
                guard count > 0 else { return }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
        }
    }
}
