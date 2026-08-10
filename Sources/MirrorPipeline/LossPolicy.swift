// SPDX-License-Identifier: GPL-3.0-or-later
//
/// deviceterm's deliberate policy around RTP loss. RFC 7798 defines how to
/// reconstruct packets but not whether a decoder should consume a damaged
/// picture; this discards the damaged one and waits for a complete keyframe, so
/// a partial slice never poisons the decoder's reference chain.
struct LossPolicy: Sendable {
    enum Verdict: Sendable, Equatable {
        case decode
        case discardCorrupt
        case discardUntilKeyframe
    }

    private var lastSequence: UInt16?
    private var accessUnitHadGap = false
    private(set) var awaitingKeyframe = false
    private(set) var highestSequence: UInt32 = 0

    /// Record one packet; return whether it introduced a gap into the current
    /// access unit. An older (reordered) packet leaves the highest value alone.
    mutating func record(sequence: UInt16) -> Bool {
        let hadGap = lastSequence.map { sequence != $0 &+ 1 } ?? false
        if hadGap { accessUnitHadGap = true }
        if lastSequence == nil || UInt16(truncatingIfNeeded: sequence &- (lastSequence ?? 0)) < 0x8000 {
            lastSequence = sequence
            highestSequence = UInt32(sequence)
        }
        return hadGap
    }

    /// End an access unit and decide its fate. A gappy keyframe is rejected just
    /// like a gappy delta: it can't safely reseed the reference chain.
    mutating func endAccessUnit(isKeyframe: Bool) -> Verdict {
        defer { accessUnitHadGap = false }
        if accessUnitHadGap {
            awaitingKeyframe = true
            return .discardCorrupt
        }
        if awaitingKeyframe {
            guard isKeyframe else { return .discardUntilKeyframe }
            awaitingKeyframe = false
        }
        return .decode
    }

    mutating func reset() {
        lastSequence = nil
        accessUnitHadGap = false
        awaitingKeyframe = false
        highestSequence = 0
    }
}
