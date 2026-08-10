// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import InteractionRelay

/// The ordering guarantee: a suspended job on a pump is neither overtaken nor
/// interleaved by a later job on the same pump, while an independent pump keeps
/// running. This is the mechanism that keeps a multi-report gesture atomic.
struct ChannelPumpTests {
    private actor Trace {
        private(set) var events: [String] = []
        func record(_ event: String) { events.append(event) }
    }

    @Test("a later same-pump job cannot overtake or interleave a suspended one")
    func sameChannelStaysOrdered() async throws {
        let pump = ChannelPump()
        let trace = Trace()
        let (gate, open) = AsyncStream<Void>.makeStream()

        async let first: Void = pump.run {
            await trace.record("first-start")
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next() // suspend mid-job until released
            await trace.record("first-end")
        }
        // Let the first job start and suspend.
        try await Task.sleep(for: .milliseconds(30))
        async let second: Void = pump.run { await trace.record("second") }
        try await Task.sleep(for: .milliseconds(30))

        // The second job must not have run while the first is suspended.
        #expect(await trace.events == ["first-start"])

        open.yield()
        open.finish()
        _ = try await (first, second)
        #expect(await trace.events == ["first-start", "first-end", "second"])
    }

    @Test("an independent pump proceeds while another is blocked")
    func independentChannelsRunConcurrently() async throws {
        let blocked = ChannelPump()
        let free = ChannelPump()
        let (gate, open) = AsyncStream<Void>.makeStream()

        async let stuck: Void = blocked.run {
            var iterator = gate.makeAsyncIterator()
            _ = await iterator.next()
        }
        try await Task.sleep(for: .milliseconds(20))

        // The free pump completes even though the other is still blocked.
        let value = try await free.run { 42 }
        #expect(value == 42)

        open.yield()
        open.finish()
        _ = try await stuck
    }
}
