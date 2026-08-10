// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A minimal async byte pipe over a BSD socket to a device tunnel endpoint, with
/// exact-count read framing.
///
/// The blocking `connect` / `send` / `recv` syscalls run on a dedicated serial
/// queue and are surfaced as `async` through continuations, so the cooperative
/// pool is never parked on a syscall. Addresses resolve through `getaddrinfo`
/// over IPv6, which handles the routable ULA tunnel address directly.
final class ByteChannel: @unchecked Sendable {
    enum ChannelError: Error, Sendable {
        case unresolved(Int32)
        case unreachable(Int32)
        case severed
        case writeFailed(Int32)
    }

    private let host: String
    private let port: UInt16
    private let readTimeout: TimeInterval
    private let syscalls = DispatchQueue(label: "com.deviceterm.channel.socket")
    private var descriptor: Int32 = -1
    private var spillover: [UInt8] = [] // bytes read past the last exact request

    /// `readTimeout` bounds a blocking `recv` (via `SO_RCVTIMEO`) so probing a
    /// port that completes a handshake but never answers can't hang forever.
    init(host: String, port: UInt16, readTimeout: TimeInterval = 5) {
        self.host = host
        self.port = port
        self.readTimeout = readTimeout
    }

    deinit {
        // Nothing else owns this descriptor, so a channel dropped without an
        // explicit close() would leak it. Closing at deinit is safe without the
        // queue: at zero refcount no in-flight `onQueue` op (each retains self)
        // can race, and it is idempotent with close(), which resets to -1.
        if descriptor >= 0 { Foundation.close(descriptor) }
    }

    /// A `timeval` from seconds that keeps sub-second precision. Truncating 0.2s
    /// to a whole-second zero wouldn't fail: Darwin accepts a zero
    /// `SO_RCVTIMEO` and reads it as "block indefinitely", so `recv` would go
    /// unbounded instead of being capped at the interval the caller asked for.
    private static func timeval(from seconds: TimeInterval) -> timeval {
        let whole = Int(seconds)
        let fractional = Int((seconds - Double(whole)) * 1_000_000)
        return Foundation.timeval(tv_sec: whole, tv_usec: .init(fractional))
    }

    func connect(timeout: TimeInterval = 4) async throws {
        try await onQueue {
            var hints = addrinfo(
                ai_flags: 0,
                ai_family: AF_INET6,
                ai_socktype: SOCK_STREAM,
                ai_protocol: IPPROTO_TCP,
                ai_addrlen: 0,
                ai_canonname: nil,
                ai_addr: nil,
                ai_next: nil
            )
            var resolved: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(self.host, String(self.port), &hints, &resolved)
            guard status == 0, let info = resolved else { throw ChannelError.unresolved(status) }
            defer { freeaddrinfo(info) }

            let sock = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard sock >= 0 else { throw ChannelError.unreachable(errno) }

            // Disable SIGPIPE on this descriptor before anything can write to
            // it. A device endpoint can close mid-exchange: a port that accepts
            // and immediately hangs up, or a service that drops during
            // bring-up. A later `send` then fails `EPIPE`, and by default that
            // same write raises SIGPIPE, which terminates the whole daemon
            // rather than returning an error to this channel, taking every
            // unrelated pane down with it. With the option set the write
            // surfaces as `writeFailed`, which the caller already handles.
            var suppressSigpipe: Int32 = 1
            _ = setsockopt(
                sock,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &suppressSigpipe,
                socklen_t(MemoryLayout<Int32>.size)
            )

            // Bound the connect with a non-blocking attempt plus poll().
            let originalFlags = fcntl(sock, F_GETFL, 0)
            _ = fcntl(sock, F_SETFL, originalFlags | O_NONBLOCK)
            let outcome = Foundation.connect(sock, info.pointee.ai_addr, info.pointee.ai_addrlen)
            if outcome != 0, errno != EINPROGRESS {
                let failure = errno
                Foundation.close(sock)
                throw ChannelError.unreachable(failure)
            }
            if outcome != 0 {
                // poll() has no FD_SETSIZE ceiling, so it stays correct for any
                // descriptor a long-lived daemon might hold.
                var watch = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
                guard poll(&watch, 1, Int32(timeout * 1_000)) > 0 else {
                    Foundation.close(sock)
                    throw ChannelError.unreachable(ETIMEDOUT)
                }
                var socketError: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(sock, SOL_SOCKET, SO_ERROR, &socketError, &size)
                guard socketError == 0 else {
                    Foundation.close(sock)
                    throw ChannelError.unreachable(socketError)
                }
            }
            _ = fcntl(sock, F_SETFL, originalFlags) // restore blocking
            var timeout = Self.timeval(from: self.readTimeout)
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            self.descriptor = sock
        }
    }

    func send(_ bytes: [UInt8]) async throws {
        try await onQueue {
            guard self.descriptor >= 0 else { throw ChannelError.severed }
            try bytes.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var sent = 0
                while sent < bytes.count {
                    let written = Foundation.send(self.descriptor, base.advanced(by: sent), bytes.count - sent, 0)
                    if written <= 0 { throw ChannelError.writeFailed(errno) }
                    sent += written
                }
            }
        }
    }

    /// Read exactly `count` bytes: wait until all of them arrive, the peer
    /// closes, or the receive timeout expires. A close and a timeout both
    /// surface as a thrown `severed`.
    func readExactly(_ count: Int) async throws -> [UInt8] {
        try await onQueue {
            guard self.descriptor >= 0 else { throw ChannelError.severed }
            if self.spillover.count >= count {
                let head = Array(self.spillover.prefix(count))
                self.spillover.removeFirst(count)
                return head
            }
            var collected = self.spillover
            self.spillover.removeAll(keepingCapacity: true)
            var scratch = [UInt8](repeating: 0, count: 65_536)
            while collected.count < count {
                let got = scratch.withUnsafeMutableBytes { Foundation.recv(self.descriptor, $0.baseAddress, 65_536, 0) }
                if got <= 0 { throw ChannelError.severed }
                collected.append(contentsOf: scratch[0..<got])
            }
            if collected.count > count {
                self.spillover = Array(collected[count...])
                collected.removeLast(collected.count - count)
            }
            return collected
        }
    }

    func close() {
        syscalls.sync {
            if self.descriptor >= 0 {
                Foundation.close(self.descriptor)
                self.descriptor = -1
            }
        }
    }

    /// Run a blocking closure on the socket's serial queue, surfaced as async.
    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            syscalls.async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
