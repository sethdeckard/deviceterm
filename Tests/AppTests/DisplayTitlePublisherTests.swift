// SPDX-License-Identifier: GPL-3.0-or-later
//
// The GUI half of the live tab label: coalescing a shell's prompt-redraw
// burst into one RPC, keeping order without a per-push sequence number,
// abandoning a value whose session is gone, giving up on a transport that
// structurally can't accept the method (for good, or until the daemon
// behind it is replaced), and re-sending an
// UNCHANGED title after a reconnect (the daemon's cache is memory-only, so
// nothing else would ever put the label back).

@testable import App
import DaemonProtocol
import Foundation
import Testing

/// Records every push and can be scripted to fail.
@MainActor
private final class TitleSink {
    private(set) var pushes: [(sessionId: String, title: String?)] = []
    /// Errors thrown per call, consumed from the front; a `nil` entry (or an
    /// empty queue) succeeds.
    var failures: [Error?] = []

    func send(_ sessionId: String, _ title: String?) throws {
        record(sessionId, title)
        if !failures.isEmpty, let error = failures.removeFirst() { throw error }
    }

    /// Records a push without consulting `failures`, allowing a test to park
    /// the send before throwing an inline failure.
    func record(_ sessionId: String, _ title: String?) {
        pushes.append((sessionId, title))
    }
}

/// Parks a send so a test can act while it is in flight.
@MainActor
private final class Gate {
    var open = false

    func wait() async {
        await yieldUntil { self.open }
    }
}

/// Yield until `condition` holds, bounded so a wedged test fails loudly.
@MainActor
private func yieldUntil(_ condition: () -> Bool) async {
    for _ in 0..<2_000 {
        if condition() { return }
        await Task.yield()
    }
    #expect(Bool(false), "condition never became true")
}

@MainActor
private func makePublisher(_ sink: TitleSink) -> DisplayTitlePublisher {
    // No-delay sleeps so coalescing and backoff run without real time.
    DisplayTitlePublisher(
        .init(
            send: { sessionId, title in try sink.send(sessionId, title) },
            sleep: { _ in true }
        )
    )
}

/// Yield until the publisher has nothing queued or in flight (bounded).
/// The bound is a hang guard, so it asserts rather than returning quietly:
/// a publisher that never settles is the failure, not the push count that
/// would be checked afterward.
@MainActor
private func drain(_ publisher: DisplayTitlePublisher) async {
    await yieldUntil { publisher.isSettledForTesting }
}

@MainActor
struct DisplayTitlePublisherTests {
    @Test
    func coalescesABurstIntoOneSendOfTheLatestValue() async {
        // A shell can emit a burst of OSC title updates while redrawing a
        // prompt; a push per update would be an RPC storm.
        let sink = TitleSink()
        let publisher = makePublisher(sink)
        publisher.update(sessionId: "S1", title: "one")
        publisher.update(sessionId: "S1", title: "two")
        publisher.update(sessionId: "S1", title: "three")
        await drain(publisher)

        #expect(sink.pushes.count == 1)
        #expect(sink.pushes.first?.title == "three")
    }

    @Test
    func skipsAnUnchangedValue() async {
        let sink = TitleSink()
        let publisher = makePublisher(sink)
        publisher.update(sessionId: "S1", title: "same")
        await drain(publisher)
        publisher.update(sessionId: "S1", title: "same")
        await drain(publisher)

        #expect(sink.pushes.count == 1)
    }

    @Test
    func normalizesBeforeComparingSoAHostileTitleIsPushedOnce() async {
        // Two raw titles that normalize to the same value are one push: the
        // skip-cache holds the normalized form.
        let sink = TitleSink()
        let publisher = makePublisher(sink)
        publisher.update(sessionId: "S1", title: "vim")
        await drain(publisher)
        publisher.update(sessionId: "S1", title: "vim\u{202A}")
        await drain(publisher)

        #expect(sink.pushes.map(\.title) == ["vim"])
    }

    @Test
    func sendsAClearWhenTheTitleNormalizesToNothing() async {
        // Non-empty in, nothing survives: the clear must be TRANSMITTED, or
        // the previous label outlives the value that replaced it.
        let sink = TitleSink()
        let publisher = makePublisher(sink)
        publisher.update(sessionId: "S1", title: "vim")
        await drain(publisher)
        publisher.update(sessionId: "S1", title: "\u{202A}\u{202C}")
        await drain(publisher)

        #expect(sink.pushes.count == 2)
        #expect(sink.pushes.last?.title == nil)
    }

    @Test
    func republishesUnderTheNewPrimarySession() async {
        // Closing the primary terminal of a split tab re-seats the tab's
        // representative session; the same title has to land under the new one.
        let sink = TitleSink()
        let publisher = makePublisher(sink)
        publisher.update(sessionId: "S1", title: "vim")
        await drain(publisher)
        publisher.update(sessionId: "S2", title: "vim")
        await drain(publisher)

        #expect(sink.pushes.map(\.sessionId) == ["S1", "S2"])
    }

    @Test
    func ignoresAnEmptySessionId() async {
        // A tab whose state has already been removed resolves to "": pushing
        // it would only earn an unknown-session rejection.
        let sink = TitleSink()
        let publisher = makePublisher(sink)
        publisher.update(sessionId: "", title: "vim")
        await drain(publisher)

        #expect(sink.pushes.isEmpty)
    }

    @Test
    func republishResendsAnUnchangedTitleAfterAReconnect() async {
        // The daemon's cache is memory-only. Without this the skip-cache would
        // suppress the push and `tabs.list` would report the session name
        // until the next OSC event, which may never come.
        let sink = TitleSink()
        let publisher = makePublisher(sink)
        publisher.update(sessionId: "S1", title: "vim")
        await drain(publisher)
        publisher.republish()
        await drain(publisher)

        #expect(sink.pushes.count == 2)
        #expect(sink.pushes.last?.title == "vim")
    }

    @Test
    func republishLandingDuringAnInFlightSendIsNotLost() async {
        // A reconnect fires from the client's observers with no regard for
        // whether a round-trip is outstanding. If the send's resumption
        // recorded its value as sent, it would erase the republish and leave
        // nothing pending until the next title CHANGE, the very event
        // republish exists not to depend on.
        let sink = TitleSink()
        let gate = Gate()
        let publisher = DisplayTitlePublisher(
            .init(
                send: { sessionId, title in
                    try sink.send(sessionId, title)
                    if sink.pushes.count == 1 { await gate.wait() }
                },
                sleep: { _ in true }
            )
        )
        publisher.update(sessionId: "S1", title: "vim")
        await yieldUntil { sink.pushes.count == 1 }
        publisher.republish()
        gate.open = true
        await drain(publisher)

        #expect(sink.pushes.count == 2)
        #expect(sink.pushes.last?.title == "vim")
    }

    @Test
    func retriesAfterATransportFailure() async {
        let sink = TitleSink()
        sink.failures = [DaemonClientError.transport("dropped")]
        let publisher = makePublisher(sink)
        publisher.update(sessionId: "S1", title: "vim")
        await drain(publisher)

        #expect(sink.pushes.count == 2)
        #expect(sink.pushes.allSatisfy { $0.title == "vim" })
    }

    @Test
    func abandonsAValueWhoseSessionIsGoneButKeepsPublishing() async {
        // `-32001` here means "unknown session": retrying that exact value is
        // pointless, but the tab may still re-seat onto a live session.
        let sink = TitleSink()
        sink.failures = [DaemonClientError.daemon(code: -32_001, message: "unknown session")]
        let publisher = makePublisher(sink)
        publisher.update(sessionId: "S1", title: "vim")
        await drain(publisher)
        #expect(sink.pushes.count == 1)

        publisher.update(sessionId: "S2", title: "vim")
        await drain(publisher)
        #expect(sink.pushes.map(\.sessionId) == ["S1", "S2"])
        #expect(publisher.isStoppedForTesting == false)
    }

    @Test
    func stopsForGoodOnARoleViolation() async {
        // The `--smoke` UDS fallback carries no audit token, which is a
        // property of how the app was launched: no reconnect changes it.
        // One refusal, then silence, not one per prompt redraw.
        let sink = TitleSink()
        sink.failures = [DaemonClientError.daemon(code: -32_011, message: "role violation")]
        let publisher = makePublisher(sink)
        publisher.update(sessionId: "S1", title: "vim")
        await drain(publisher)
        #expect(sink.pushes.count == 1)
        #expect(publisher.isStoppedForTesting)

        publisher.update(sessionId: "S1", title: "emacs")
        publisher.republish()
        await drain(publisher)
        #expect(sink.pushes.count == 1)
        #expect(publisher.isStoppedForTesting)
    }

    @Test
    func aMethodNotFoundStopsOnlyThisConnection() async {
        // A stale helper predating the method refuses every push, so stop
        // asking it. But an idle exit or a crash replaces that helper
        // without the GUI restarting, and the replacement supports the
        // method. Staying off until the tab reopens would leave the new
        // daemon with no titles at all.
        let sink = TitleSink()
        sink.failures = [DaemonClientError.daemon(code: -32_601, message: "unknown method")]
        let publisher = makePublisher(sink)
        publisher.update(sessionId: "S1", title: "vim")
        await drain(publisher)
        #expect(sink.pushes.count == 1)
        #expect(publisher.isStoppedForTesting)

        // Still off for THIS connection: a further title change asks nothing.
        publisher.update(sessionId: "S1", title: "emacs")
        await drain(publisher)
        #expect(sink.pushes.count == 1)

        // The reconnect re-arms it, and the current title goes to the
        // replacement daemon.
        publisher.republish()
        await drain(publisher)
        #expect(publisher.isStoppedForTesting == false)
        #expect(sink.pushes.map(\.title) == ["vim", "emacs"])
    }

    @Test
    func aStaleMethodNotFoundDoesNotDisableTheReplacement() async {
        // A reconnect can land while a doomed push is still in flight. The
        // refusal that comes back afterward is the OLD connection's verdict;
        // applying it would stop publishing on the replacement, the very
        // daemon that supports the method, and strand the pending title
        // until the tab reopens.
        let sink = TitleSink()
        let gate = Gate()
        let publisher = DisplayTitlePublisher(
            .init(
                send: { sessionId, title in
                    sink.record(sessionId, title)
                    guard sink.pushes.count == 1 else { return }
                    await gate.wait()
                    throw DaemonClientError.daemon(code: -32_601, message: "unknown method")
                },
                sleep: { _ in true }
            )
        )
        publisher.update(sessionId: "S1", title: "vim")
        await yieldUntil { sink.pushes.count == 1 }
        publisher.republish()
        gate.open = true
        await drain(publisher)

        #expect(publisher.isStoppedForTesting == false)
        #expect(sink.pushes.map(\.title) == ["vim", "vim"])
    }

    @Test
    func cancelDropsAPendingPush() async {
        // Title-change-then-close: the tab's sessions are closing, so a late
        // push would only be rejected.
        let sink = TitleSink()
        let publisher = makePublisher(sink)
        publisher.update(sessionId: "S1", title: "vim")
        publisher.cancel()
        await drain(publisher)

        #expect(sink.pushes.isEmpty)
        #expect(publisher.isStoppedForTesting)
    }
}
