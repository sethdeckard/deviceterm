// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import DaemonProtocol
import Foundation
import Testing

/// The GUI drain loop's handling of a
/// back-channel scope refusal, and of a command that outlived its deadline.
///
/// A signature rejection (-32011) is terminal on
/// BOTH transports: the `--smoke` UDS fallback (structural, can't ever
/// validate) and a genuine XPC signature mismatch (retrying can't fix a stable
/// verdict). A transient validation-unavailable outcome is a distinct code
/// (-32002) that stays on the retry path.
///
/// The expiry tests read the ack rather than instrumenting the dispatcher,
/// because `expiredCode` is the one error code the dispatch path cannot
/// produce: seeing it is the same claim as "the dispatcher was never
/// reached".
@MainActor
struct AppCommandSubscriberTests {
    /// Fake back-channel that always refuses the subscription with a
    /// configurable wire code, counting attempts.
    private final class RefusingBackChannel: AppCommandControlling {
        let code: Int
        var attempts = 0

        init(code: Int = -32_011) { self.code = code }

        func subscribeAppCommands() async throws
        -> (initial: Data, events: AsyncStream<(String, Data)>) {
            attempts += 1
            await Task.yield()
            throw DaemonClientError.daemon(code: code, message: "refused")
        }

        func sendAppCommandResult(_ result: AppCommandResult) async {
            await Task.yield()
        }
    }

    /// Back-channel that hands out one live stream the test feeds by
    /// hand, and records every ack the subscriber sends back.
    private final class ScriptedBackChannel: AppCommandControlling {
        private var continuation: AsyncStream<(String, Data)>.Continuation?
        private(set) var results: [AppCommandResult] = []
        /// Emitting before this is true drops the frame on the floor: the
        /// continuation doesn't exist yet, so the yield goes nowhere and
        /// the test hangs waiting for an ack that was never provoked.
        var isSubscribed: Bool { continuation != nil }

        func subscribeAppCommands() async
        -> (initial: Data, events: AsyncStream<(String, Data)>) {
            await Task.yield()
            let (stream, cont) = AsyncStream<(String, Data)>.makeStream()
            // Only the first subscription is driveable. A re-subscribe
            // (which this test never provokes) parks on a stream that
            // never yields rather than silently stealing the handle.
            if continuation == nil {
                continuation = cont
            }
            return (Data(), stream)
        }

        func sendAppCommandResult(_ result: AppCommandResult) async {
            await Task.yield()
            results.append(result)
        }

        func emit(_ command: AppCommand) throws {
            let payload = try JSONEncoder().encode(command)
            continuation?.yield(("app.command", payload))
        }
    }

    /// A `windows.list` command, optionally stamped with a deadline.
    /// `windowsList` is the cheapest kind to dispatch for real: it reads
    /// the (empty) workspace and answers `.data`, so a dispatched command
    /// is distinguishable from a declined one by status alone.
    private func windowsListCommand(
        expiresAtMonotonicNanos: UInt64?
    ) -> AppCommand {
        AppCommand(
            commandId: "cmd-\(expiresAtMonotonicNanos.map(String.init) ?? "none")",
            kind: .windowsList,
            originatingSessionId: nil,
            params: Data(#"{"all":false}"#.utf8),
            expiresAtMonotonicNanos: expiresAtMonotonicNanos
        )
    }

    private func makeDispatcher() -> IntentDispatcher {
        let workspace = WorkspaceViewModel()
        let router = Router(workspace: workspace, daemon: FakeDaemonClient())
        return IntentDispatcher(
            workspace: workspace,
            router: router,
            actionDelegate: nil
        )
    }

    private func waitUntil(
        _ deadlineSeconds: Double,
        _ condition: () -> Bool
    ) async -> Bool {
        let end = Date().addingTimeInterval(deadlineSeconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    @Test
    func signatureRefusalStopsDrainLoop() async {
        // -32011 is a STABLE signature rejection (either transport); retrying
        // can't fix a cached verdict, so the loop must stop after one attempt.
        let fake = RefusingBackChannel(code: -32_011)
        let subscriber = AppCommandSubscriber(
            dispatcher: makeDispatcher(),
            daemon: fake
        )
        subscriber.start()
        // The drain task must terminate after a single refused attempt:
        // awaiting its value completes only if the loop returned.
        await subscriber.drainTask?.value
        #expect(fake.attempts == 1)
    }

    @Test
    func transientValidationUnavailableKeepsRetrying() async {
        // -32002 is the retryable validation-unavailable outcome; the loop
        // must attempt again after the first refusal, not stop.
        let fake = RefusingBackChannel(code: -32_002)
        let subscriber = AppCommandSubscriber(
            dispatcher: makeDispatcher(),
            daemon: fake
        )
        subscriber.start()
        let retried = await waitUntil(3) { fake.attempts >= 2 }
        #expect(retried)
        subscriber.stop()
    }

    // MARK: - Expiry

    /// The phantom write: a command that sat buffered past its reply
    /// deadline is still queued here, and dispatching it would perform
    /// the mutation potentially after the caller received an error.
    @Test
    func expiredCommandIsDeclinedWithoutDispatching() async throws {
        let fake = ScriptedBackChannel()
        let subscriber = AppCommandSubscriber(
            dispatcher: makeDispatcher(),
            daemon: fake
        )
        subscriber.start()
        #expect(await waitUntil(3) { fake.isSubscribed })
        // A deadline one second in the past, so there is no race with
        // however long the drain takes to pick the frame up.
        let past = AppCommandDeadline.nowMonotonicNanos() - 1_000_000_000
        try fake.emit(windowsListCommand(expiresAtMonotonicNanos: past))
        let acked = await waitUntil(3) { !fake.results.isEmpty }
        #expect(acked)
        #expect(fake.results.first?.status == "error")
        #expect(fake.results.first?.error?.code == AppCommandDeadline.expiredCode)
        subscriber.stop()
    }

    @Test
    func unexpiredCommandDispatchesNormally() async throws {
        let fake = ScriptedBackChannel()
        let subscriber = AppCommandSubscriber(
            dispatcher: makeDispatcher(),
            daemon: fake
        )
        subscriber.start()
        #expect(await waitUntil(3) { fake.isSubscribed })
        let future = AppCommandDeadline.expiry(inMs: 60_000)
        try fake.emit(windowsListCommand(expiresAtMonotonicNanos: future))
        let acked = await waitUntil(3) { !fake.results.isEmpty }
        #expect(acked)
        // "data" is what a real `windows.list` dispatch answers with, so
        // this asserts the command ran rather than merely that it wasn't
        // declined for expiry.
        #expect(fake.results.first?.status == "data")
        subscriber.stop()
    }

    /// Back-compat: a daemon that predates the field sends no expiry, and
    /// its commands must run rather than be discarded wholesale.
    @Test
    func unstampedCommandDispatchesNormally() async throws {
        let fake = ScriptedBackChannel()
        let subscriber = AppCommandSubscriber(
            dispatcher: makeDispatcher(),
            daemon: fake
        )
        subscriber.start()
        #expect(await waitUntil(3) { fake.isSubscribed })
        try fake.emit(windowsListCommand(expiresAtMonotonicNanos: nil))
        let acked = await waitUntil(3) { !fake.results.isEmpty }
        #expect(acked)
        // "data" is what a real `windows.list` dispatch answers with, so
        // this asserts the command ran rather than merely that it wasn't
        // declined for expiry.
        #expect(fake.results.first?.status == "data")
        subscriber.stop()
    }
}
