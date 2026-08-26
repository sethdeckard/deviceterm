// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import DaemonProtocol
import Foundation
import Testing

/// Exercise the daemon-side back-channel
/// broker: subscribe, publish + await, deliver result, timeout, and
/// subscriber-loss cleanup.
struct AppCommandCoordinatorTests {
    // MARK: - Helpers

    private func waitForPendingCount(
        _ coord: AppCommandCoordinator,
        equals expected: Int,
        timeoutSeconds: Double = 2
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let count = await coord.pendingCount
            if count == expected { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    // MARK: - Subscribe flow

    @Test
    func subscribeRegistersTheActiveSubscriber() async {
        let coord = AppCommandCoordinator()
        var initial = await coord.hasSubscriber
        #expect(!initial)
        let (_, onCancel) = await coord.subscribe(connectionId: 1)
        let withSub = await coord.hasSubscriber
        #expect(withSub)
        onCancel()
        // Cancel runs asynchronously; allow the actor to process.
        try? await Task.sleep(nanoseconds: 20_000_000)
        initial = await coord.hasSubscriber
        #expect(!initial)
    }

    @Test
    func secondSubscribeReplacesTheFirst() async {
        let coord = AppCommandCoordinator()
        let (stream1, _) = await coord.subscribe(connectionId: 1)
        let (stream2, _) = await coord.subscribe(connectionId: 2)
        // Stream 1 should finish when stream 2 takes over.
        let drained1 = Task {
            var count = 0
            for await _ in stream1 { count += 1 }
            return count
        }
        _ = stream2  // hold the stream so it stays subscribed
        let count = await drained1.value
        #expect(count == 0)
    }

    // MARK: - Publish + await

    @Test
    func publishAndAwaitDeliversTheResult() async {
        let coord = AppCommandCoordinator()
        let (stream, _) = await coord.subscribe(connectionId: 1)
        // Spin a task that consumes the published command and acks.
        Task {
            for await command in stream {
                await coord.deliverResult(
                    .ok(commandId: command.commandId),
                    from: 1
                )
                break
            }
        }
        let outcome = await coord.publishAndAwait(
            kind: .tabClose,
            originatingSessionId: "S-A",
            params: Data(#"{"tab":{"type":"current"},"mode":"detach"}"#.utf8)
        )
        if case .ok = outcome {
            // success
        } else {
            Issue.record("expected .ok; got \(outcome)")
        }
    }

    @Test
    func publishWithoutSubscriberFailsImmediately() async {
        let coord = AppCommandCoordinator()
        let outcome = await coord.publishAndAwait(
            kind: .windowsList,
            originatingSessionId: nil,
            params: Data(#"{"all":false}"#.utf8)
        )
        if case let .error(code, _) = outcome {
            #expect(code == "intent.guiUnavailable")
        } else {
            Issue.record("expected .error; got \(outcome)")
        }
    }

    @Test
    func publishTimesOutWhenGUINeverReplies() async {
        let coord = AppCommandCoordinator()
        let (stream, _) = await coord.subscribe(connectionId: 1)
        // Drain the stream so the publish actually yields, then drop
        // every command without acking (simulates a wedged GUI).
        let dropper = Task {
            for await _ in stream { /* drop */ }
        }
        let outcome = await coord.publishAndAwait(
            kind: .windowsList,
            originatingSessionId: nil,
            params: Data(#"{"all":false}"#.utf8),
            timeoutMs: 50
        )
        if case let .error(code, _) = outcome {
            #expect(code == "intent.guiUnavailable")
        } else {
            Issue.record("expected .error; got \(outcome)")
        }
        dropper.cancel()
    }

    /// Verifies that publication stamps an expiry using the requested
    /// timeout. It does not observe when the timeout task fires; the two
    /// share a duration, not an instant.
    @Test
    func publishStampsAnExpiryFromTheRequestedTimeout() async throws {
        let coord = AppCommandCoordinator()
        let (stream, _) = await coord.subscribe(connectionId: 1)
        let timeoutMs = 30_000
        let before = AppCommandDeadline.nowMonotonicNanos()
        let publishTask = Task {
            await coord.publishAndAwait(
                kind: .windowsList,
                originatingSessionId: nil,
                params: Data(#"{"all":false}"#.utf8),
                timeoutMs: timeoutMs
            )
        }
        var iterator = stream.makeAsyncIterator()
        let command = try #require(await iterator.next())
        let after = AppCommandDeadline.nowMonotonicNanos()
        let expiry = try #require(command.expiresAtMonotonicNanos)
        let budget = UInt64(timeoutMs) * 1_000_000
        // Bracketed by readings taken either side of the publish, so the
        // assertion holds however long the actor hop took.
        #expect(expiry >= before + budget)
        #expect(expiry <= after + budget)
        publishTask.cancel()
        _ = await coord.deliverResult(.ok(commandId: command.commandId), from: 1)
    }

    /// The daemon's budget has to stay strictly under the CLI's to
    /// reserve any time at all for its coded refusal to get back before
    /// the transport deadline. The two constants are read by different
    /// modules, so nothing but this guard keeps them from re-converging.
    @Test
    func daemonDeadlineStaysUnderTheCLIRequestTimeout() {
        let cliMs = AppCommandDeadline.cliRequestTimeoutSeconds * 1_000
        #expect(Double(AppCommandCoordinator.defaultTimeoutMs) < cliMs)
        #expect(Double(AppCommandDeadline.guiReplyTimeoutMs) < cliMs)
    }

    @Test
    func subscriberLossFailsPendingCommands() async {
        let coord = AppCommandCoordinator()
        let (stream, onCancel) = await coord.subscribe(connectionId: 1)
        // Subscribe a drain that holds the stream open but never acks.
        let dropper = Task {
            for await _ in stream { /* drop */ }
        }
        // Publish + immediately drop the subscriber.
        let publishTask = Task {
            await coord.publishAndAwait(
                kind: .tabInfo,
                originatingSessionId: nil,
                params: Data(#"{"tab":{"type":"current"}}"#.utf8),
                timeoutMs: 5_000
            )
        }
        let pendingArrived = await waitForPendingCount(coord, equals: 1)
        #expect(pendingArrived)
        onCancel()
        let outcome = await publishTask.value
        if case let .error(code, _) = outcome {
            #expect(code == "intent.guiUnavailable")
        } else {
            Issue.record("expected .error; got \(outcome)")
        }
        dropper.cancel()
    }

    // MARK: - Result delivery

    @Test
    func unknownCommandIdFromSubscriberIsAcceptedAndDropped() async {
        let coord = AppCommandCoordinator()
        _ = await coord.subscribe(connectionId: 1)
        // A result from the correct subscriber for an unknown/expired
        // commandId is not a violation. It's accepted (a post-timeout
        // reply) and silently dropped rather than crashing.
        let accepted = await coord.deliverResult(
            .ok(commandId: "no-such-id"),
            from: 1
        )
        #expect(accepted)
        let count = await coord.pendingCount
        #expect(count == 0)
    }
}
