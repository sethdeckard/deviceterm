// SPDX-License-Identifier: GPL-3.0-or-later
//
/// Turns RTP/HEVC payloads into complete NAL units (RFC 7798): passing single
/// NALs through, unpacking Aggregation Packets, and reassembling Fragmentation
/// Units across packets.
///
/// The in-progress fragment buffer persists across calls, so feed payloads in
/// arrival order. Completed NALs come back with their 2-byte HEVC header intact
/// but no start code or length prefix; the caller prefixes as its decoder needs.
struct AccessUnitAssembler {
    // HEVC NAL unit types.
    static let idrWRadl: UInt8 = 19
    static let idrNLP: UInt8 = 20
    static let cra: UInt8 = 21
    static let vps: UInt8 = 32
    static let sps: UInt8 = 33
    static let pps: UInt8 = 34
    private static let aggregationPacket: UInt8 = 48
    private static let fragmentationUnit: UInt8 = 49

    private var fragment: [UInt8] = []

    /// The NAL unit type from a NAL's first byte.
    static func nalType(_ nal: [UInt8]) -> UInt8 {
        guard let first = nal.first else { return 0 }
        return (first >> 1) & 0x3F
    }

    /// True for an IDR/CRA keyframe NAL type.
    static func isKeyframe(_ type: UInt8) -> Bool {
        type == idrWRadl || type == idrNLP || type == cra
    }

    /// Drop the in-progress fragment. Call on detected loss so a half-built NAL
    /// doesn't corrupt the next picture.
    mutating func reset() {
        fragment.removeAll(keepingCapacity: true)
    }

    /// Process one RTP payload (after the 12-byte RTP header), returning any NAL
    /// units it completes.
    mutating func accept(_ payload: [UInt8]) -> [[UInt8]] {
        guard payload.count >= 2 else { return [] }
        switch (payload[0] >> 1) & 0x3F {
        case Self.aggregationPacket:
            return unpackAggregation(payload)

        case Self.fragmentationUnit:
            return continueFragment(payload)

        default:
            return [payload]
        }
    }

    /// Aggregation packets are all-or-nothing: a truncated one yields nothing,
    /// so an incomplete picture can't splice into a clean access unit.
    private func unpackAggregation(_ payload: [UInt8]) -> [[UInt8]] {
        var units: [[UInt8]] = []
        var index = 2
        while index < payload.count {
            guard index + 2 <= payload.count else { return [] }
            let size = (Int(payload[index]) << 8) | Int(payload[index + 1])
            index += 2
            guard size > 0, index + size <= payload.count else { return [] }
            units.append(Array(payload[index..<index + size]))
            index += size
        }
        return units
    }

    private mutating func continueFragment(_ payload: [UInt8]) -> [[UInt8]] {
        guard payload.count >= 3 else { return [] }
        let fragmentHeader = payload[2]
        let starts = (fragmentHeader & 0x80) != 0
        let ends = (fragmentHeader & 0x40) != 0
        let nalUnitType = fragmentHeader & 0x3F
        if starts {
            // Rebuild the 2-byte NAL header: the FU carries the type separately;
            // reinsert it while keeping the forbidden-zero bit and temporal id.
            let header: [UInt8] = [(payload[0] & 0x81) | (nalUnitType << 1), payload[1]]
            fragment = header + payload[3...]
        } else {
            // A middle/end fragment with no start has no recoverable header, so
            // ignore it until the next valid FU start.
            guard !fragment.isEmpty else { return [] }
            fragment.append(contentsOf: payload[3...])
        }
        if ends, !fragment.isEmpty {
            defer { fragment.removeAll(keepingCapacity: true) }
            return [fragment]
        }
        return []
    }
}
