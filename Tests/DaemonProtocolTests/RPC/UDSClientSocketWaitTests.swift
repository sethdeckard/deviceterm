// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

// These socket-pair tests cover a waited timeout, available data, peer
// closure, and an expired deadline, so no daemon or listener is involved.
// The loose bounds catch premature timeout or an unexpectedly long block.

/// A connected local socket pair, closed when the test scope ends. `left`
/// stands in for the client fd, `right` for the peer that writes or closes.
private struct SocketPair: ~Copyable {
    let left: Int32
    private var right: Int32

    init() throws {
        var fds: [Int32] = [0, 0]
        let rc = fds.withUnsafeMutableBufferPointer { buf in
            socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        try #require(rc == 0, "socketpair failed: \(errno)")
        left = fds[0]
        right = fds[1]
    }

    deinit {
        _ = close(left)
        if right >= 0 { _ = close(right) }
    }

    /// Close the peer end so `left` sees EOF, and forget the descriptor so
    /// `deinit` can't close it twice. The second close would otherwise land
    /// on whatever number the kernel had since handed out, and these suites
    /// run in parallel.
    mutating func closeRight() {
        _ = close(right)
        right = -1
    }

    /// Write one byte from the peer end so `left` has something to read.
    func writeByte() {
        var byte: UInt8 = 0x2A
        #expect(write(right, &byte, 1) == 1)
    }
}

/// Milliseconds spent inside `body`, measured on the monotonic clock so a
/// wall-clock adjustment can't turn a pass into a failure.
private func elapsedMilliseconds(_ body: () -> Void) -> Double {
    let start = ContinuousClock.now
    body()
    let duration = ContinuousClock.now - start
    return Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000
}

@Test
func waitReadableReportsTimeoutAfterWaitingOutTheDeadline() throws {
    let pair = try SocketPair()
    var readable = true
    let elapsed = elapsedMilliseconds {
        readable = UDSClientSocket.waitReadable(
            fd: pair.left,
            deadline: Date(timeIntervalSinceNow: 0.05)
        )
    }
    #expect(readable == false)
    // An unreadable descriptor waits until its deadline.
    #expect(elapsed >= 40)
}

@Test
func waitReadableReturnsAsSoonAsThePeerWrites() throws {
    let pair = try SocketPair()
    pair.writeByte()
    var readable = false
    let elapsed = elapsedMilliseconds {
        readable = UDSClientSocket.waitReadable(
            fd: pair.left,
            deadline: Date(timeIntervalSinceNow: 5)
        )
    }
    #expect(readable)
    // A readable descriptor returns well before the five-second deadline.
    #expect(elapsed < 1_000)
}

@Test
func waitReadableReportsPeerCloseInsteadOfWaitingOutTheDeadline() throws {
    var pair = try SocketPair()
    pair.closeRight()
    var readable = false
    let elapsed = elapsedMilliseconds {
        readable = UDSClientSocket.waitReadable(
            fd: pair.left,
            deadline: Date(timeIntervalSinceNow: 5)
        )
    }
    // EOF is readable, so the caller's `readAvailable` sees the close now
    // rather than after the full timeout.
    #expect(readable)
    #expect(elapsed < 1_000)
}

@Test
func waitReadableReportsTimeoutImmediatelyForAnElapsedDeadline() throws {
    let pair = try SocketPair()
    var readable = true
    let elapsed = elapsedMilliseconds {
        readable = UDSClientSocket.waitReadable(
            fd: pair.left,
            deadline: Date(timeIntervalSinceNow: -1)
        )
    }
    #expect(readable == false)
    #expect(elapsed < 1_000)
}
