// SPDX-License-Identifier: GPL-3.0-or-later
//
// UDSListenerSocket: the server half of the harness's private Unix-
// domain socket, self-contained inside this target.
//
// `Daemon`'s `UDSSocket` has an equivalent listener, but it lives in the
// `Daemon` library, which transitively links CoreSimulator, a dependency
// the test harness must not take (it stays a small, decoupled
// instrument). The client half already exists Foundation-only as
// `DaemonProtocol.UDSClientSocket`, which this target reuses; only the
// ~145 lines of bind/accept/read/write server boilerplate are duplicated
// here, mirroring the deliberate split documented on `UDSClientSocket`.
//
// Unlike the daemon's non-blocking + `DispatchSourceRead` design, this
// listener stays *blocking* and is driven from a dedicated background
// thread (see `ResidentServer`): one request per accepted connection,
// read to a full frame, reply, close. Simpler, and adequate for a test
// harness's request volume.

import DaemonProtocol
import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum UDSListenerSocketError: Error, Equatable {
    case socketFailed(errno: Int32)
    case bindFailed(errno: Int32, path: String)
    case listenFailed(errno: Int32)
    case acceptFailed(errno: Int32)
    case readFailed(errno: Int32)
    case writeFailed(errno: Int32)
    case socketPathTooLong(path: String)
    case socketPathExists(path: String)
    /// A peer connected but didn't finish sending (or reading) a frame
    /// within `ioTimeoutSeconds`. The connection is dropped rather than
    /// held open.
    case timedOut
}

enum UDSListenerSocket {
    /// macOS reserves 104 bytes for `sockaddr_un.sun_path`; one is the
    /// trailing NUL, so the practical ceiling is 103.
    static let maxPathLength = 103

    /// Per-connection I/O deadline. A peer that connects and then never
    /// sends a complete frame (or never drains the reply) must not pin
    /// a worker forever, so both directions are bounded.
    static let ioTimeoutSeconds = 5

    /// Create, bind, and `listen(2)` on a socket at `path`, returning the
    /// (blocking) listener fd. A *stale* socket left by a crashed resident
    /// is unlinked and replaced; a path owned by a *live* listener, or a
    /// non-socket file, throws `socketPathExists`.
    static func bindListener(at path: String, backlog: Int32 = 16) throws -> Int32 {
        guard path.utf8.count <= maxPathLength else {
            throw UDSListenerSocketError.socketPathTooLong(path: path)
        }
        if FileManager.default.fileExists(atPath: path) {
            guard isSocket(at: path), !isListenerAlive(at: path) else {
                throw UDSListenerSocketError.socketPathExists(path: path)
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UDSListenerSocketError.socketFailed(errno: errno) }
        setNoSigPipe(fd: fd)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        copyPath(path, into: &addr)

        let bindRC = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindRC < 0 {
            let saved = errno
            close(fd)
            throw UDSListenerSocketError.bindFailed(errno: saved, path: path)
        }
        if listen(fd, backlog) < 0 {
            let saved = errno
            unlink(path)
            close(fd)
            throw UDSListenerSocketError.listenFailed(errno: saved)
        }
        return fd
    }

    /// Block until one connection arrives; return the (blocking) client fd.
    /// Retries `EINTR`.
    static func acceptOne(listenerFd: Int32) throws -> Int32 {
        while true {
            var addr = sockaddr_un()
            var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFd = withUnsafeMutablePointer(to: &addr) { addrPtr -> Int32 in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(listenerFd, sa, &addrLen)
                }
            }
            if clientFd >= 0 {
                setNoSigPipe(fd: clientFd)
                // Bound both directions so a silent or non-draining peer
                // can't hold this connection (and its worker) open forever.
                setIOTimeouts(fd: clientFd, seconds: ioTimeoutSeconds)
                return clientFd
            }
            let saved = errno
            if saved == EINTR { continue }
            throw UDSListenerSocketError.acceptFailed(errno: saved)
        }
    }

    /// Blocking-read one length-prefixed frame from `fd`, subject to the
    /// `SO_RCVTIMEO` deadline set in `acceptOne`.
    /// - Returns the payload bytes, or `nil` on EOF before a full frame.
    /// - Throws `timedOut` if the peer stalls mid-frame.
    static func readFrame(fd: Int32, cap: Int = RPCFraming.defaultPayloadCap) throws -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4_096)
        while true {
            if let frame = try RPCFraming.decodeNext(from: buffer, cap: cap) {
                return frame.payload
            }
            let n = chunk.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.append(chunk, count: n)
            } else if n == 0 {
                return nil
            } else {
                let saved = errno
                if saved == EINTR { continue }
                // With `SO_RCVTIMEO` set, EAGAIN means the deadline expired.
                if saved == EAGAIN || saved == EWOULDBLOCK {
                    throw UDSListenerSocketError.timedOut
                }
                throw UDSListenerSocketError.readFailed(errno: saved)
            }
        }
    }

    /// Frame `payload` and write every byte to `fd`. Retries `EINTR`.
    static func writeFrame(fd: Int32, payload: Data) throws {
        let data = RPCFraming.encode(payload)
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
                    // With `SO_SNDTIMEO` set, EAGAIN means the peer stopped
                    // draining; drop the connection rather than spin.
                    if saved == EAGAIN || saved == EWOULDBLOCK {
                        throw UDSListenerSocketError.timedOut
                    }
                    throw UDSListenerSocketError.writeFailed(errno: saved)
                }
            }
        }
    }

    static func close(_ fd: Int32) { _ = Darwin.close(fd) }

    // MARK: - Internal helpers

    private static func copyPath(_ path: String, into addr: inout sockaddr_un) {
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: maxPathLength + 1) { dest in
                path.withCString { src in _ = strncpy(dest, src, maxPathLength + 1) }
            }
        }
    }

    private static func isSocket(at path: String) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.type] as? FileAttributeType) == .typeSocket
    }

    /// Whether a process is actively listening at `path`. A definitive
    /// `ECONNREFUSED`/`ENOENT` means dead (safe to replace); anything
    /// else is treated as alive so we never steal a running resident's
    /// socket.
    ///
    /// The connect is **non-blocking**: a live-but-wedged resident (full
    /// accept backlog, stuck accept loop) must not hang the probe, which
    /// would in turn hang `bindListener` and `serve` startup. An
    /// in-progress connect (`EINPROGRESS`) or a saturated backlog counts
    /// as alive, so we never unlink a socket a running resident owns.
    private static func isListenerAlive(at path: String) -> Bool {
        guard path.utf8.count <= maxPathLength else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        setNonBlocking(fd: fd)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        copyPath(path, into: &addr)
        let rc = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc == 0 { return true }
        let err = errno
        return err != ECONNREFUSED && err != ENOENT
    }

    private static func setNonBlocking(fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    private static func setNoSigPipe(fd: Int32) {
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Apply a receive + send deadline to an accepted connection.
    private static func setIOTimeouts(fd: Int32, seconds: Int) {
        var deadline = timeval(tv_sec: seconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, size)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &deadline, size)
    }
}
