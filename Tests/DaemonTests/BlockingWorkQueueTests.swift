// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Dispatch
import Testing

@Test
func blockingWorkQueueSerializesSubmittedOperations() async {
    let queue = BlockingWorkQueue(label: "com.deviceterm.tests.blocking-work")
    let releaseFirst = DispatchSemaphore(value: 0)
    let (events, eventContinuation) = AsyncStream.makeStream(of: Int.self)
    var iterator = events.makeAsyncIterator()

    let first = Task {
        await queue.run {
            eventContinuation.yield(1)
            releaseFirst.wait()
            eventContinuation.yield(2)
            return 1
        }
    }
    #expect(await iterator.next() == 1)

    let second = Task {
        await queue.run {
            eventContinuation.yield(3)
            return 2
        }
    }

    releaseFirst.signal()
    #expect(await iterator.next() == 2)
    #expect(await iterator.next() == 3)
    #expect(await first.value == 1)
    #expect(await second.value == 2)
    eventContinuation.finish()
}

private enum BlockingWorkTestError: Error, Equatable {
    case expected
}

@Test
func blockingWorkQueuePropagatesErrors() async {
    let queue = BlockingWorkQueue(label: "com.deviceterm.tests.blocking-error")

    await #expect(throws: BlockingWorkTestError.expected) {
        _ = try await queue.run { () throws -> Int in
            throw BlockingWorkTestError.expected
        }
    }
}
