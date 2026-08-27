// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

// The pipeline hands frames out through a one-deep `.bufferingNewest(1)`
// stream and counts a coalescing drop from the `YieldResult`. Both halves of
// that contract belong to the standard library, and a change to either would
// silently zero the counter rather than fail a build, so they are pinned here.
//
// The pipeline's own counter cannot be driven hermetically: it increments
// inside the VideoToolbox output path, which needs a live device.
//
// Every case holds the stream for the whole test. Letting it go deallocates it,
// after which every yield answers `.terminated` and the drop assertions below
// would pass or fail for the wrong reason.

@Test("a full one-deep buffer answers `.dropped`, which is what the drop counter counts")
func bufferingNewestReportsADropWhenItEvicts() {
    let (stream, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
    withExtendedLifetime(stream) {
        guard case .enqueued = continuation.yield(1) else {
            Issue.record("the first yield into an empty buffer should enqueue")
            return
        }
        guard case .dropped = continuation.yield(2) else {
            Issue.record("yielding into a full one-deep buffer should report a drop")
            return
        }
    }
}

@Test("`.dropped` names the evicted frame, not the one just yielded")
func theDroppedElementIsTheOlderOne() {
    let (stream, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
    withExtendedLifetime(stream) {
        _ = continuation.yield(1)
        guard case let .dropped(evicted) = continuation.yield(2) else {
            Issue.record("yielding into a full one-deep buffer should report a drop")
            return
        }
        // If this ever became the newly yielded element, the count would still
        // be right but the comment at the call site would be wrong.
        #expect(evicted == 1)
    }
}

@Test("the consumer sees the newest frame, so coalescing preserves freshness")
func theSurvivingElementIsTheNewest() async {
    let (stream, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
    for value in 1...4 { _ = continuation.yield(value) }
    continuation.finish()
    var received: [Int] = []
    for await value in stream { received.append(value) }
    #expect(received == [4])
}

@Test("a finished stream reports `.terminated`, which is not a drop")
func terminationIsDistinctFromADrop() {
    let (stream, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
    withExtendedLifetime(stream) {
        continuation.finish()
        guard case .terminated = continuation.yield(1) else {
            Issue.record("yielding after finish should report termination")
            return
        }
    }
}

@Test("a released stream terminates its continuation, which is not a drop either")
func releasingTheStreamTerminatesTheContinuation() {
    let continuation: AsyncStream<Int>.Continuation
    do {
        let (stream, made) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation = made
        _ = stream
    }
    guard case .terminated = continuation.yield(1) else {
        Issue.record("yielding after the stream is released should report termination")
        return
    }
}
