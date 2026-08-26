// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Thin POSIX wrappers for the daemon's Unix domain socket.
///
/// macOS's `Network.framework` (`NWListener`/`NWConnection`) doesn't
/// support `AF_UNIX`, so the daemon talks straight to the BSD socket
/// API. These helpers wrap the parts we actually use (listener
/// bind+listen, single-shot accept, non-blocking read of whatever's
/// available, blocking write-all) and translate errno values into
/// typed Swift errors.
///
/// Everything here is `Sendable` and free of shared mutable state;
/// the actor layers above own per-fd state and call into these
/// functions from their isolation domain.
public enum UDSSocket {
    /// Upper bound on the `sun_path` byte length. macOS reserves 104
    /// bytes for `sun_path` in `sockaddr_un`; one byte is reserved for
    /// the trailing NUL so the practical limit is 103.
    public static let maxPathLength: Int = 103

    // MARK: - Listener

    /// Create, bind, and listen on a Unix domain socket at `path`.
    /// Sets the listening fd to non-blocking so `acceptOne` can be
    /// driven from a `DispatchSourceRead` without blocking its queue.
    /// On success returns the listening fd; on failure cleans up any
    /// partial state and throws.
    ///
    /// A *stale* socket left by a previous daemon that exited uncleanly
    /// (SIGKILL / crash skips the unlink in `applicationWillTerminate`)
    /// is unlinked and replaced. Otherwise it would wedge every future
    /// daemon spawn. A path with a *live* listener, or a non-socket
    /// file, still throws `socketPathExists`.
    public static func bindListener(at path: String, backlog: Int32 = 16) throws -> Int32 {
        guard path.utf8.count <= maxPathLength else {
            throw UDSSocketError.socketPathTooLong(path: path)
        }
        // Self-heal a stale socket; refuse a live listener or a
        // non-socket file (don't steal a running daemon's path or
        // clobber an unrelated file).
        if FileManager.default.fileExists(atPath: path) {
            guard isSocket(at: path), !isListenerAlive(at: path) else {
                throw UDSSocketError.socketPathExists(path: path)
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UDSSocketError.socketFailed(errno: errno)
        }
        setNoSigPipe(fd: fd)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bindResult = withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr -> Int32 in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: maxPathLength + 1) { dest in
                path.withCString { src in
                    _ = strncpy(dest, src, maxPathLength + 1)
                }
                return 0
            }
        }
        _ = bindResult  // suppress unused warning

        let bindRC = withUnsafePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindRC < 0 {
            let saved = errno
            close(fd)
            throw UDSSocketError.bindFailed(errno: saved, path: path)
        }

        if listen(fd, backlog) < 0 {
            let saved = errno
            unlink(path)
            close(fd)
            throw UDSSocketError.listenFailed(errno: saved)
        }

        setNonBlocking(fd: fd)
        return fd
    }

    /// Try to accept one pending connection.
    /// - Returns `nil` if no connection is pending (`EAGAIN` /
    ///   `EWOULDBLOCK`). Caller's `DispatchSourceRead` will fire again
    ///   when one becomes available.
    /// - Returns a non-blocking client fd on success.
    public static func acceptOne(listenerFd: Int32) throws -> Int32? {
        var addr = sockaddr_un()
        var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFd = withUnsafeMutablePointer(to: &addr) { addrPtr -> Int32 in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                accept(listenerFd, sa, &addrLen)
            }
        }
        if clientFd < 0 {
            let saved = errno
            if saved == EAGAIN || saved == EWOULDBLOCK { return nil }
            throw UDSSocketError.acceptFailed(errno: saved)
        }
        // Disable SIGPIPE on this accepted fd. Without this, a client
        // that disconnects between sending its request and receiving
        // a response would kill the daemon when the response write
        // hits EPIPE: `write(2)` raises SIGPIPE first, before
        // returning -1 with errno=EPIPE.
        setNoSigPipe(fd: clientFd)
        setNonBlocking(fd: clientFd)
        return clientFd
    }

    // MARK: - Connect (client side; used by tests)

    /// Open a non-blocking client socket and `connect(2)` to a
    /// listener at `path`. Returns the connected fd. Tests use this
    /// directly; production CLI / GUI clients have their own (mostly
    /// identical) versions inside their respective binaries.
    public static func connectClient(to path: String) throws -> Int32 {
        guard path.utf8.count <= maxPathLength else {
            throw UDSSocketError.socketPathTooLong(path: path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw UDSSocketError.socketFailed(errno: errno)
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
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc < 0 {
            let saved = errno
            close(fd)
            throw UDSSocketError.connectFailed(errno: saved, path: path)
        }
        // The function's docstring (and its callers, including the
        // test harness) expects a non-blocking fd so `readAvailable`
        // returns immediately when no data is buffered. Without this,
        // `read(2)` would block past the test's timeout loop and the
        // suite could hang instead of failing cleanly.
        setNonBlocking(fd: fd)
        return fd
    }

    // MARK: - Read / write

    /// Read all currently-available bytes from `fd` non-blockingly.
    /// - Returns `nil` on EOF (peer closed).
    /// - Returns an empty `Data` if nothing is available right now.
    /// - Returns accumulated bytes when partial data is followed by
    ///   EAGAIN.
    /// - Throws on any other read error.
    /// Retries `EINTR` internally; ignores `EAGAIN`/`EWOULDBLOCK` and
    /// returns what's been collected so far.
    public static func readAvailable(fd: Int32, chunkSize: Int = 4_096) throws -> Data? {
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var collected = Data()
        while true {
            let n = buffer.withUnsafeMutableBufferPointer { bufPtr -> ssize_t in
                read(fd, bufPtr.baseAddress, bufPtr.count)
            }
            if n > 0 {
                collected.append(buffer, count: n)
                if n < chunkSize { return collected }
                // exactly chunk-full, so loop to drain more
            } else if n == 0 {
                return collected.isEmpty ? nil : collected
            } else {
                let saved = errno
                if saved == EAGAIN || saved == EWOULDBLOCK { return collected }
                if saved == EINTR { continue }
                throw UDSSocketError.readFailed(errno: saved)
            }
        }
    }

    /// Write all bytes of `data` to `fd`. Loops until the full buffer
    /// has been written or a non-recoverable error fires. Retries
    /// `EINTR`. For UDS, `EAGAIN` on write is rare; when it happens we briefly
    /// back off and retry. `RPCConnection` invokes this on its per-connection
    /// blocking queue, never its actor's cooperative-executor worker.
    /// REFACTOR: Replace the 1 ms EAGAIN polling with a write-side
    /// `DispatchSource`.
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
                        // 1ms backoff. Sufficient at our request rate.
                        usleep(1_000)
                        continue
                    }
                    throw UDSSocketError.writeFailed(errno: saved)
                }
            }
        }
    }

    // MARK: - Internal helpers

    /// Whether the filesystem entry at `path` is a Unix-domain socket.
    /// Guards the stale-socket self-heal so `bindListener` never unlinks
    /// a regular file that happens to share the path.
    private static func isSocket(at path: String) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.type] as? FileAttributeType) == .typeSocket
    }

    /// Whether a process is actively listening on the socket at `path`.
    /// Used by `bindListener` to tell a stale socket (safe to replace)
    /// from one a live daemon owns.
    ///
    /// The connect is **non-blocking**: a live-but-wedged daemon (full
    /// accept backlog, stuck accept loop) must not hang the probe, and
    /// thus `bindListener`, during startup. Only a definitive
    /// `ECONNREFUSED` (nobody listening) or a vanished file counts as
    /// "not alive"; an in-progress connect, a saturated backlog, or any
    /// other transient error is treated as a live listener, so we never
    /// unlink a socket a still-running daemon owns.
    private static func isListenerAlive(at path: String) -> Bool {
        guard path.utf8.count <= maxPathLength else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        setNonBlocking(fd: fd)
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

    /// Disable SIGPIPE delivery on writes to this socket. On macOS the
    /// canonical way is the `SO_NOSIGPIPE` socket option (Linux uses
    /// `MSG_NOSIGNAL` per-send instead, which doesn't exist here).
    /// After this, a write to a peer-closed socket returns -1 with
    /// `errno == EPIPE` and the caller can handle it as a normal
    /// I/O error instead of being terminated by an asynchronous
    /// signal. Applied to every accepted fd and every client fd.
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
