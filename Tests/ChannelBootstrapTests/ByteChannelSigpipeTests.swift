// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import ChannelBootstrap

/// Writing to a device endpoint that hung up must fail this channel, not the
/// process.
///
/// A tunnel endpoint can accept a connection and close it immediately: a port
/// that is listening but not the service being probed, or a service that drops
/// during bring-up. A later write then fails `EPIPE`, and without
/// `SO_NOSIGPIPE` that same write raises SIGPIPE, whose default disposition
/// terminates the daemon outright and takes every unrelated pane with it.
///
/// The expectation names `EPIPE` rather than accepting any write failure,
/// because `EPIPE` is the code that carries the signal. Also accepting
/// `ECONNRESET` would let a regressed build pass on a run that never reached
/// the SIGPIPE path. SIGPIPE is not a thrown Swift error, and this test
/// installs no handler for it, so under the default disposition a regressed
/// build terminates this test process before any expectation can fail.
struct ByteChannelSigpipeTests {
    @Test("a peer that hangs up fails the write instead of the process")
    func hungUpPeerSurfacesAsWriteFailure() async throws {
        let listener = try HangUpListener()
        defer { listener.close() }
        let channel = ByteChannel(host: "::1", port: listener.port, readTimeout: 0.2)
        try await channel.connect()
        defer { channel.close() }

        // The peer is already gone, but the first write can still be accepted
        // into the local send buffer before the reset arrives, so retry until
        // one fails.
        var caught: (any Error)?
        for _ in 0..<50 {
            do {
                try await channel.send([UInt8](repeating: 0xAB, count: 4_096))
            } catch {
                caught = error
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let failure = try #require(caught as? ByteChannel.ChannelError)
        guard case let .writeFailed(code) = failure else {
            Issue.record("expected writeFailed, got \(failure)")
            return
        }
        #expect(code == EPIPE)
    }
}

/// A loopback TCP listener that accepts one connection and immediately closes
/// it, reproducing a device port that answers but vends nothing.
private final class HangUpListener: @unchecked Sendable {
    enum ListenerError: Error {
        case unavailable(Int32)
    }

    let port: UInt16
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "com.deviceterm.tests.hangup-listener")

    /// IPv6 throughout, matching the ULA tunnel address a real device channel
    /// resolves. `ByteChannel` pins `getaddrinfo` to `AF_INET6`, so an IPv4
    /// listener would be reachable only through Darwin's `::ffff:` mapping.
    init() throws {
        let listenerDescriptor = socket(AF_INET6, SOCK_STREAM, 0)
        guard listenerDescriptor >= 0 else { throw ListenerError.unavailable(errno) }
        var reuse: Int32 = 1
        _ = setsockopt(listenerDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_loopback
        address.sin6_port = 0 // let the kernel pick a free port
        let bound = withUnsafePointer(to: &address) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenerDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0, listen(listenerDescriptor, 8) == 0 else {
            Foundation.close(listenerDescriptor)
            throw ListenerError.unavailable(errno)
        }
        var assigned = sockaddr_in6()
        var size = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listenerDescriptor, $0, &size)
            }
        }
        guard named == 0 else {
            Foundation.close(listenerDescriptor)
            throw ListenerError.unavailable(errno)
        }
        port = assigned.sin6_port.bigEndian
        descriptor = listenerDescriptor
        queue.async {
            while true {
                let peer = accept(listenerDescriptor, nil, nil)
                if peer < 0 { return }
                Foundation.close(peer)
            }
        }
    }

    func close() {
        Foundation.close(descriptor)
    }
}
