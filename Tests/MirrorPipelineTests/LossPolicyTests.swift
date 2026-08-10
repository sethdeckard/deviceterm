// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import MirrorPipeline

/// The loss-recovery policy: decode contiguous units, discard gappy ones, and
/// wait for a complete keyframe after loss.
struct LossPolicyTests {
    @Test("a contiguous access unit decodes")
    func contiguousDecodes() {
        var policy = LossPolicy()
        let firstGap = policy.record(sequence: 40)
        let secondGap = policy.record(sequence: 41)
        let decision = policy.endAccessUnit(isKeyframe: false)
        #expect(!firstGap)
        #expect(!secondGap)
        #expect(decision == .decode)
    }

    @Test("a gappy access unit waits for a complete keyframe")
    func gappyWaitsForKeyframe() {
        var policy = LossPolicy()
        _ = policy.record(sequence: 40)
        let gap = policy.record(sequence: 42)
        let corruptVerdict = policy.endAccessUnit(isKeyframe: true)
        #expect(gap)
        #expect(corruptVerdict == .discardCorrupt)
        #expect(policy.awaitingKeyframe)
        _ = policy.record(sequence: 43)
        let deltaVerdict = policy.endAccessUnit(isKeyframe: false)
        #expect(deltaVerdict == .discardUntilKeyframe)
        _ = policy.record(sequence: 44)
        let keyframeVerdict = policy.endAccessUnit(isKeyframe: true)
        #expect(keyframeVerdict == .decode)
        #expect(!policy.awaitingKeyframe)
    }

    @Test("a sequence wrap preserves the current highest packet")
    func sequenceWrapPreservesHighest() {
        var policy = LossPolicy()
        _ = policy.record(sequence: UInt16.max)
        let wrapGap = policy.record(sequence: 0)
        #expect(!wrapGap) // wrap, not a gap
        #expect(policy.highestSequence == 0)
    }
}
