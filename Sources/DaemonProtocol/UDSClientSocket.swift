// SPDX-License-Identifier: GPL-3.0-or-later
//
// UDSClientSocket: the client half of the daemon's Unix-domain
// socket transport, usable without importing `Daemon`.
//
// `Daemon`'s `UDSSocket` keeps the server side (`bindListener` /
// `acceptOne`) plus its own test-facing `connectClient`. This is a
// deliberate, small duplication of the ~80 lines of connect/read/
// write boilerplate: deduplicating would force `UDSSocket` (and the
// 23 `@testable import Daemon` test files that exercise it) to move,
// which would touch every existing daemon test for no functional gain.
// The GUI `DaemonClient` and `deviceterm-cli` link only `DaemonProtocol`,
// so the client primitive has to live here.
//
// `connect(to:)` returns a non-blocking fd. Pair with `readAvailable`
// in a poll/decode loop and `writeAll` for framed requests.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum UDSClientSocketError: Error, Equatable, Sendable {
    case socketFailed(
        errno:
        Int32
        )
    case connectFailed(
        errno:
        Int32,
        path: String
        )
    case socketPathTooLong(
        path:
        String
        )
    case readFailed(
        errno:
        Int32
        )
    case writeFailed(
        errno:
        Int32
        )
}

public enum UDSClientSocket {
    /// macOS reserves 104 bytes for `sockaddr_un.sun_path`; one is the
    /// trailing NUL, so the practical ceiling is 103.
    public static let maxPathLength: Int = 103

    /// Open a non-blocking client socket and `connect(2)` to the
    /// listener at `path`. `SO_NOSIGPIPE` is set so a write to a
    /// peer-closed socket returns `EPIPE` instead of killing the
    /// process with an async signal.
    public static func connect(to path: String) throws -> Int32 {
        guard path.utf8.count <= maxPathLength else {
            throw UDSClientSocketError.socketPathTooLong(path: path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UDSClientSocketError.socketFailed(errno: errno)
        }
        setNoSigPipe(fd: fd)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: maxPathLength + 1) { dest in
                path.withCString { src in
                    _ = strncpy(dest, src, maxPathLength + 1)
                }
            }
        }
        let rc = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc < 0 {
            let saved = errno
            close(fd)
            throw UDSClientSocketError.connectFailed(errno: saved, path: path)
        }
        setNonBlocking(fd: fd)
        return fd
    }

    /// Read all currently-available bytes non-blockingly.
    /// - Returns `nil` on EOF (peer closed).
    /// - Returns an empty `Data` if nothing is buffered right now.
    /// - Returns accumulated bytes when partial data is followed by
    ///   `EAGAIN`.
    /// Retries `EINTR`; ignores `EAGAIN`/`EWOULDBLOCK`.
    public static func readAvailable(fd: Int32, chunkSize: Int = 4_096) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var collected = Data()
        while true {
            let n = buffer.withUnsafeMutableBufferPointer { bufPtr -> Int in
                read(fd, bufPtr.baseAddress, bufPtr.count)
            }
            if n > 0 {
                collected.append(buffer, count: n)
                if n < chunkSize { return collected }
            } else if n == 0 {
                return collected.isEmpty ? nil : collected
            } else {
                let saved = errno
                if saved == EAGAIN || saved == EWOULDBLOCK { return collected }
                if saved == EINTR { continue }
                throw UDSClientSocketError.readFailed(errno: saved)
            }
        }
    }

    /// Write every byte of `data`, looping until done. Retries
    /// `EINTR`; backs off 1ms on `EAGAIN` (rare on UDS at our volume).
    public static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { rawBuf in
            guard var ptr = rawBuf.baseAddress else { return }
            var remaining = rawBuf.count
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n > 0 {
                    ptr = ptr.advanced(by: n)
                    remaining -= n
                } else {
                    let saved = errno
                    if saved == EINTR { continue }
                    if saved == EAGAIN || saved == EWOULDBLOCK {
                        usleep(1_000)
                        continue
                    }
                    throw UDSClientSocketError.writeFailed(errno: saved)
                }
            }
        }
    }

    /// Close a fd opened by `connect(to:)`.
    public static func close(_ fd: Int32) {
        _ = Darwin.close(fd)
    }

    // MARK: - Internal helpers

    private static func setNonBlocking(fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    private static func setNoSigPipe(fd: Int32) {
        var yes: Int32 = 1
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &yes,
            socklen_t(MemoryLayout<Int32>.size)
            )
    }
}
