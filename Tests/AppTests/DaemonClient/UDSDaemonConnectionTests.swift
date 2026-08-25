// SPDX-License-Identifier: GPL-3.0-or-later
//
// UDSDaemonConnectionTests: the cancellation contract of the smoke-mode
// socket transport, exercised against a genuinely silent peer.
//
// A `socketpair` gives the connection a live socket whose far end simply
// never writes back, which is what a wedged daemon looks like from here: the
// connection stays open (so nothing errors) and the reply never comes (so the
// continuation parks). Without a cancellation handler that park is permanent,
// and a deadline racing the call would wait on the loser forever instead of
// expiring. These tests pin that a cancelled call resumes exactly once,
// promptly, and leaves no pending entry behind.

@testable import App
import DaemonProtocol
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#endif

@MainActor
struct UDSDaemonConnectionTests {
    /// A connected socket pair: the connection owns `fd`, and `peerFD` is the
    /// far end, held open and never written to. The connection closes `fd`
    /// itself when its read source cancels, so only `peerFD` is the caller's
    /// to close.
    private func makeSilentPeer() throws -> (connection: UDSDaemonConnection, peerFD: Int32) {
        var fds: [Int32] = [0, 0]
        let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        try #require(result == 0, "socketpair failed: \(errno)")
        return (UDSDaemonConnection(fd: fds[0]), fds[1])
    }

    /// Poll `box` until the call under test records its outcome, or the bound
    /// expires. Polling rather than awaiting the task's value on purpose: a
    /// call that never resumes is exactly the bug these tests exist to catch,
    /// and awaiting it would hang the run instead of failing it.
    private func outcome(of box: OutcomeBox, within seconds: Double = 2.0) async -> String {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let value = await box.value { return value }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await box.value ?? "still parked"
    }

    @Test
    func aCancelledRequestResumesWithCancellationError() async throws {
        let (connection, peerFD) = try makeSilentPeer()
        defer { close(peerFD) }
        let box = OutcomeBox()
        let task = Task {
            await box.record(
                classify {
                    _ = try await connection.request(
                        method: RPCMethod.deviceList.rawValue,
                        params: nil
                    )
                }
            )
        }
        // Let the send reach the io queue and park, so this exercises the
        // cancel-after-registration path rather than the pre-send refusal.
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        #expect(await outcome(of: box) == "cancelled")
    }

    @Test
    func aRequestCancelledBeforeItIsSentIsStillRefused() async throws {
        let (connection, peerFD) = try makeSilentPeer()
        defer { close(peerFD) }
        let box = OutcomeBox()
        let task = Task {
            await box.record(
                classify {
                    _ = try await connection.request(
                        method: RPCMethod.deviceList.rawValue,
                        params: nil
                    )
                }
            )
        }
        // No sleep: the cancel races the hop onto the io queue, so it may
        // land before the request is ever registered. Both orderings must end
        // the same way, which is why the cancellation state is carried on a
        // ticket the send also reads.
        task.cancel()
        #expect(await outcome(of: box) == "cancelled")
    }

    @Test
    func closingAfterACancelledRequestDoesNotResumeItTwice() async throws {
        let (connection, peerFD) = try makeSilentPeer()
        defer { close(peerFD) }
        let box = OutcomeBox()
        let task = Task {
            await box.record(
                classify {
                    _ = try await connection.request(
                        method: RPCMethod.deviceList.rawValue,
                        params: nil
                    )
                }
            )
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        #expect(await outcome(of: box) == "cancelled")
        // `close` fails every pending entry. If the cancelled request were
        // still in that map, its checked continuation would be resumed a
        // second time, which traps and takes the whole test process down:
        // finishing this test at all is the assertion that the entry was
        // dropped.
        connection.close()
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    @Test
    func aCancelledSubscribeResumesWithCancellationError() async throws {
        let (connection, peerFD) = try makeSilentPeer()
        defer { close(peerFD) }
        let box = OutcomeBox()
        let task = Task {
            await box.record(
                classify {
                    _ = try await connection.subscribe(
                        method: RPCMethod.paneSubscribe.rawValue,
                        params: nil
                    )
                }
            )
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        #expect(await outcome(of: box) == "cancelled")
        // Both maps this time: `close` also finishes every subscription it
        // still holds, so surviving it proves the subscribe left neither
        // entry behind.
        connection.close()
        try await Task.sleep(nanoseconds: 100_000_000)
    }
}

/// Run `call` and name how it ended, so a test can assert the outcome rather
/// than the absence of a throw.
@MainActor
private func classify(_ call: () async throws -> Void) async -> String {
    do {
        try await call()
        return "returned"
    } catch is CancellationError {
        return "cancelled"
    } catch {
        return "\(error)"
    }
}

/// Single-slot recorder for the outcome of a call made from another task.
private actor OutcomeBox {
    private(set) var value: String?

    func record(_ outcome: String) { value = outcome }
}
