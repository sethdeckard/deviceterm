// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A host UDP/IPv6 socket that streams received datagrams and sends feedback
/// back over the same port (RTP and RTCP are multiplexed).
///
/// The socket is bound before the stream is started (the device pushes RTP the
/// instant it answers), and `boundPort` is the value handed to it as the
/// receiver port. Bound on `::` so the tunnel interface is covered.
final class DatagramIngress: @unchecked Sendable {
    enum IngressError: Error, Sendable {
        case bindFailed(Int32)
    }

    let boundPort: UInt16

    private let descriptor: Int32
    private let receiveQueue = DispatchQueue(label: "com.deviceterm.mirror.udp")
    // Serialises `send` against `close` and guards the one-time close. Separate
    // from `receiveQueue`: the recv loop occupies that, so syncing on it would
    // deadlock. Without this gate a concurrent close could shut and reuse the fd
    // number while a `sendto` is mid-flight, and the restart path could
    // double-close and tear down an unrelated socket after fd reuse.
    private let closeGate = DispatchQueue(label: "com.deviceterm.mirror.udp.close")
    private var closed = false

    init() throws {
        let sock = socket(AF_INET6, SOCK_DGRAM, 0)
        guard sock >= 0 else { throw IngressError.bindFailed(errno) }

        // Enlarge the kernel receive buffer (8 MB, 4 MB fallback). High on-screen
        // motion spikes the encoder bitrate; a small buffer overflows between
        // recv() calls and the kernel silently drops datagrams, surfacing as HEVC
        // slice loss. A big buffer absorbs the bursts.
        var receiveBuffer: Int32 = 8 * 1_024 * 1_024
        if setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            receiveBuffer = 4 * 1_024 * 1_024
            _ = setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_any
        address.sin6_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Foundation.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0 else {
            let failure = errno
            Foundation.close(sock)
            throw IngressError.bindFailed(failure)
        }

        var assigned = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &length)
            }
        }
        self.descriptor = sock
        self.boundPort = UInt16(bigEndian: assigned.sin6_port)
    }

    /// A stream of received datagrams (full RTP/RTCP packets). Starts the receive
    /// loop on first call; it ends when the socket is closed.
    func datagrams() -> AsyncStream<[UInt8]> {
        AsyncStream { continuation in
            receiveQueue.async { [weak self] in
                guard let self else { continuation.finish(); return }
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    // recv returns <= 0 once the socket is shut down / closed;
                    // that's how the loop (and stream) terminate.
                    let count = buffer.withUnsafeMutableBytes { recv(self.descriptor, $0.baseAddress, 65_536, 0) }
                    if count <= 0 { break }
                    continuation.yield(Array(buffer[0..<count]))
                }
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in self?.close() }
        }
    }

    /// Send a feedback datagram to the device from this socket. The tunnel
    /// address is a routable ULA, so no scope id is needed. Fire-and-forget.
    /// Serialised against `close` so a `sendto` can't run on a closed (and
    /// possibly reused) descriptor.
    func send(_ datagram: [UInt8], toHost host: String, port: UInt16) {
        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        guard host.withCString({ inet_pton(AF_INET6, $0, &address.sin6_addr) }) == 1 else { return }
        closeGate.sync {
            guard !closed else { return }
            _ = datagram.withUnsafeBytes { payload in
                withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(
                            descriptor,
                            payload.baseAddress,
                            datagram.count,
                            0,
                            $0,
                            socklen_t(MemoryLayout<sockaddr_in6>.size)
                        )
                    }
                }
            }
        }
    }

    /// Wake any blocked `recv` and close the socket, exactly once. `shutdown`
    /// first so a receive loop parked in `recv` returns immediately. Idempotent
    /// and serialised with `send` on `closeGate`, so no `sendto` observes the
    /// descriptor after it is closed, and a second close (after fd reuse) can't
    /// tear down an unrelated socket. The gate is independent of `receiveQueue`,
    /// so waking the parked `recv` here cannot deadlock.
    func close() {
        closeGate.sync {
            guard !closed else { return }
            closed = true
            shutdown(descriptor, SHUT_RDWR)
            Foundation.close(descriptor)
        }
    }
}
