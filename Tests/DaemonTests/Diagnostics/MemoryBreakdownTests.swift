// SPDX-License-Identifier: GPL-3.0-or-later

@testable import Daemon
import Foundation
import Testing

/// The breakdown written when the daemon's footprint escalates or reaches its
/// ceiling. What is pinned: the tag names a reader will grep for, the ordering
/// that puts the largest contributor first, and the line lengths unified
/// logging will carry intact.
struct MemoryBreakdownTests {
    @Test("known tags print the names vmmap uses", arguments: [
        (0, "VM_ALLOCATE"),
        (1, "MALLOC"),
        (11, "MALLOC_NANO"),
        (21, "IOKIT"),
        (30, "STACK"),
        (42, "COREGRAPHICS"),
        (88, "IOSURFACE"),
        (100, "IOACCELERATOR"),
        (240, "APP_SPECIFIC_1"),
        (255, "APP_SPECIFIC_16")
    ] as [(UInt32, String)])
    func namesTheKnownTags(tag: UInt32, expected: String) {
        #expect(VMMemoryTag.name(tag) == expected)
    }

    @Test
    func printsAnUnknownTagNumerically() {
        // A tag this table does not know is still evidence: the number is
        // enough to look it up.
        #expect(VMMemoryTag.name(199) == "tag199")
    }

    @Test
    func theBreakdownOrdersTagsByDirtyPlusCompressed() {
        // Resident bytes can include clean file-backed pages, which the kernel
        // does not charge to the footprint. The tag to name first is the one
        // whose pages are dirty or in the compressor.
        let breakdown = MemoryBreakdown(
            vmInfo: nil,
            regionTotals: [
                VMRegionTagTotal(
                    tag: 1,
                    regions: 4,
                    virtualBytes: 600 * 1_048_576,
                    residentBytes: 500 * 1_048_576,
                    dirtyBytes: 10 * 1_048_576,
                    compressedBytes: 0
                ),
                VMRegionTagTotal(
                    tag: 88,
                    regions: 6,
                    virtualBytes: 400 * 1_048_576,
                    residentBytes: 10 * 1_048_576,
                    dirtyBytes: 100 * 1_048_576,
                    compressedBytes: 300 * 1_048_576
                )
            ],
            regionsWalked: 10,
            mallocZones: []
        )
        let lines = breakdown.lines()
        #expect(lines.count == 3)
        #expect(lines[1].hasPrefix("regions: walked=10 IOSURFACE:dirty=100MiB/comp=300MiB/res=10MiB/n=6 MALLOC:"))
        #expect(lines[2] == "malloc:")
    }

    @Test
    func theBreakdownLinesStayUnderTheLogLimit() {
        // Unified logging truncates a long interpolated argument. A breakdown
        // with hundreds of tags must still fit, cut from the tail, and a zone
        // whose name alone exceeds the limit is cut short rather than dropped,
        // because it sorts first and is the one entry the line exists for.
        let totals = (0 ..< 300).map { index in
            VMRegionTagTotal(
                tag: UInt32(index),
                regions: 10_000 + index,
                virtualBytes: 99_999 * 1_048_576,
                residentBytes: 99_999 * 1_048_576,
                dirtyBytes: 99_999 * 1_048_576,
                compressedBytes: UInt64(99_999 - index) * 1_048_576
            )
        }
        let zones = (0 ..< 6).map { index in
            MallocZoneTotal(
                name: index == 0
                    ? String(repeating: "z", count: 1_500)
                    : "DefaultMallocZone_0x1e3f6f00\(index)",
                blocksInUse: 9_999_999,
                sizeInUse: UInt64(index == 0 ? 100_000 : 99_999) * 1_048_576,
                maxSizeInUse: 99_999 * 1_048_576,
                sizeAllocated: 99_999 * 1_048_576
            )
        }
        let info = TaskVMInfoSummary(
            physFootprint: 99_999 * 1_048_576,
            physFootprintPeak: 99_999 * 1_048_576,
            resident: 99_999 * 1_048_576,
            internalBytes: 99_999 * 1_048_576,
            external: 99_999 * 1_048_576,
            reusable: 99_999 * 1_048_576,
            compressed: 99_999 * 1_048_576,
            compressedPeak: 99_999 * 1_048_576,
            purgeableVolatileResident: 99_999 * 1_048_576,
            purgeableNonvolatile: 99_999 * 1_048_576,
            graphicsFootprint: 99_999 * 1_048_576,
            mediaFootprint: 99_999 * 1_048_576,
            networkNonvolatile: 99_999 * 1_048_576,
            regionCount: 99_999,
            pageSize: 16_384,
            limitBytesRemaining: 99_999 * 1_048_576,
            decompressions: 99_999_999,
            swapins: 99_999_999
        )
        let lines = MemoryBreakdown(
            vmInfo: info,
            regionTotals: totals,
            regionsWalked: 300,
            mallocZones: zones
        ).lines()
        #expect(lines.count == 3)
        for line in lines {
            #expect(
                line.utf8.count <= MemoryBreakdown.lineByteLimit,
                "line too long (\(line.utf8.count)): \(line.prefix(80))"
            )
        }
        #expect(lines[1].hasPrefix("regions: walked=300 VM_ALLOCATE:"))
        #expect(lines[2].hasPrefix("malloc: zzzz"))
        #expect(!lines[2].contains("DefaultMallocZone"))
    }

    @Test
    func anUnavailableVMInfoSaysSo() {
        let lines = MemoryBreakdown(vmInfo: nil, regionTotals: [], regionsWalked: 0, mallocZones: []).lines()
        #expect(lines == ["vm: unavailable", "regions: walked=0", "malloc:"])
    }

    @Test
    func theProcessReportsItsOwnBreakdown() {
        // The parts that cannot be faked: a live region walk and a live zone
        // enumeration. No exact numbers, only that each found what any Swift
        // process has: mapped regions, a malloc-tagged one among them, and a
        // zone holding blocks.
        let breakdown = MemoryBreakdownReader.read()
        #expect(breakdown.vmInfo != nil)
        #expect(breakdown.regionsWalked > 0)
        #expect(breakdown.regionTotals.contains { (1 ... 13).contains($0.tag) })
        #expect(breakdown.mallocZones.contains { $0.sizeInUse > 0 })
    }
}
