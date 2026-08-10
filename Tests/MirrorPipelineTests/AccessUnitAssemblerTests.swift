// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import MirrorPipeline

/// RFC 7798 assembly: single NALs pass through, Aggregation Packets unpack, and
/// Fragmentation Units reassemble across packets.
struct AccessUnitAssemblerTests {
    private static func nalHeader(_ type: UInt8) -> [UInt8] {
        [(type << 1) & 0x7E, 0x01] // layer 0, tid 1
    }

    @Test("a single NAL payload passes through unchanged")
    func singleNAL() {
        var assembler = AccessUnitAssembler()
        let nal = Self.nalHeader(AccessUnitAssembler.sps) + [0xAA, 0xBB]
        let out = assembler.accept(nal)
        #expect(out == [nal])
        #expect(AccessUnitAssembler.nalType(nal) == AccessUnitAssembler.sps)
    }

    @Test("an aggregation packet unpacks its NAL units")
    func aggregationPacket() {
        var assembler = AccessUnitAssembler()
        let nalA = Self.nalHeader(AccessUnitAssembler.vps) + [0x01]
        let nalB = Self.nalHeader(AccessUnitAssembler.pps) + [0x02, 0x03]
        var packet = Self.nalHeader(48) // AP type
        for nal in [nalA, nalB] {
            packet += [UInt8(nal.count >> 8), UInt8(nal.count & 0xFF)] + nal
        }
        let out = assembler.accept(packet)
        #expect(out == [nalA, nalB])
    }

    @Test("fragmentation units reassemble into one NAL")
    func fragmentationUnit() {
        var assembler = AccessUnitAssembler()
        let idrType = AccessUnitAssembler.idrWRadl
        let body: [UInt8] = Array(0..<30)

        func fu(start: Bool, end: Bool, slice: ArraySlice<UInt8>) -> [UInt8] {
            var fragmentHeader = idrType
            if start { fragmentHeader |= 0x80 }
            if end { fragmentHeader |= 0x40 }
            return [0x62, 0x01, fragmentHeader] + slice // 0x62 = FU (49) NAL header
        }

        let startOut = assembler.accept(fu(start: true, end: false, slice: body[0..<10]))
        let midOut = assembler.accept(fu(start: false, end: false, slice: body[10..<20]))
        let endOut = assembler.accept(fu(start: false, end: true, slice: body[20..<30]))
        #expect(startOut.isEmpty)
        #expect(midOut.isEmpty)
        #expect(endOut.count == 1)
        #expect(AccessUnitAssembler.nalType(endOut[0]) == idrType)
        #expect(Array(endOut[0].dropFirst(2)) == body)
    }

    @Test("key NAL types are recognized")
    func keyframeDetection() {
        #expect(AccessUnitAssembler.isKeyframe(AccessUnitAssembler.idrWRadl))
        #expect(AccessUnitAssembler.isKeyframe(AccessUnitAssembler.cra))
        #expect(!AccessUnitAssembler.isKeyframe(AccessUnitAssembler.vps))
        #expect(!AccessUnitAssembler.isKeyframe(1))
    }

    @Test("a truncated aggregation packet is discarded as a unit")
    func truncatedAggregationDiscarded() {
        var assembler = AccessUnitAssembler()
        let packet = Self.nalHeader(48) + [0x00, 0x04, 0x40, 0x01]
        let out = assembler.accept(packet)
        #expect(out.isEmpty)
    }

    @Test("an orphaned FU end fragment is discarded")
    func orphanedFragmentDiscarded() {
        var assembler = AccessUnitAssembler()
        let packet: [UInt8] = [0x62, 0x01, 0x40 | AccessUnitAssembler.idrWRadl, 0xAA]
        let out = assembler.accept(packet)
        #expect(out.isEmpty)
    }
}
