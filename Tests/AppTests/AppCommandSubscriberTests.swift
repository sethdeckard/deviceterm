// SPDX-License-Identifier: GPL-3.0-or-later
//
// AppCommandSubscriberTests: the GUI drain loop's handling of a
// back-channel scope refusal. A signature rejection (-32011) is terminal on
// BOTH transports: the `--smoke` UDS fallback (structural, can't ever
// validate) and a genuine XPC signature mismatch (retrying can't fix a stable
// verdict). A transient validation-unavailable outcome is a distinct code
// (-32002) that stays on the retry path.

@testable import App
import DaemonProtocol
import Foundation
import Testing

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
}
