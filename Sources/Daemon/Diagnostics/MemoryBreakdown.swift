// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where the process's memory sits: the kernel's accounting, the mapped
/// regions summed by VM memory tag, and the malloc zones.
///
/// Rendered as several short lines rather than one, because unified logging
/// truncates a long interpolated argument. Each line is cut to
/// `lineByteLimit` by dropping entries from its tail, which holds the
/// smallest; an entry that exceeds the limit on its own is cut short rather
/// than dropped, so the largest entry is always named.
struct MemoryBreakdown: Sendable, Equatable {
    /// How many region tags and malloc zones a rendering names at most.
    static let defaultTopCount = 12
    /// The longest line rendered, in bytes. Unified logging truncates an
    /// interpolated argument past about a kibibyte.
    static let lineByteLimit = 1_000

    var vmInfo: TaskVMInfoSummary?
    var regionTotals: [VMRegionTagTotal]
    /// Regions the walk visited, so a suspiciously short list can be told
    /// from a walk that ended early.
    var regionsWalked: Int
    var mallocZones: [MallocZoneTotal]

    /// Join `prefix` and `entries`, dropping entries from the tail until the
    /// line fits `lineByteLimit`. A lone entry still over the limit is cut to
    /// the bytes left after the prefix, so the largest entry is always named.
    private static func fit(_ prefix: String, entries: [String]) -> String {
        var kept = entries
        func joined() -> String { ([prefix] + kept).joined(separator: " ") }
        while joined().utf8.count > lineByteLimit, kept.count > 1 {
            kept.removeLast()
        }
        if joined().utf8.count > lineByteLimit, var first = kept.first {
            let budget = max(0, lineByteLimit - prefix.utf8.count - 1)
            while first.utf8.count > budget, !first.isEmpty {
                first.removeLast()
            }
            kept = [first]
        }
        return joined()
    }

    /// The `vm:`, `regions:`, and `malloc:` lines, in that order. Region tags
    /// are ordered by their footprint contribution and zones by bytes in use,
    /// each list cut to `topCount` and then to `lineByteLimit`.
    func lines(topCount: Int = MemoryBreakdown.defaultTopCount) -> [String] {
        let vmLine = vmInfo?.line ?? "vm: unavailable"
        let regions = regionTotals
            .sorted { lhs, rhs in
                lhs.footprintBytes != rhs.footprintBytes
                    ? lhs.footprintBytes > rhs.footprintBytes
                    : lhs.tag < rhs.tag
            }
            .prefix(topCount)
            .map { total in
                "\(total.name):dirty=\(TaskVMInfoSummary.mib(total.dirtyBytes))"
                    + "/comp=\(TaskVMInfoSummary.mib(total.compressedBytes))"
                    + "/res=\(TaskVMInfoSummary.mib(total.residentBytes))"
                    + "/n=\(total.regions)"
            }
        let zones = mallocZones
            .sorted { lhs, rhs in
                lhs.sizeInUse != rhs.sizeInUse ? lhs.sizeInUse > rhs.sizeInUse : lhs.name < rhs.name
            }
            .prefix(topCount)
            .map { zone in
                "\(zone.name):inUse=\(TaskVMInfoSummary.mib(zone.sizeInUse))"
                    + "/peak=\(TaskVMInfoSummary.mib(zone.maxSizeInUse))"
                    + "/allocated=\(TaskVMInfoSummary.mib(zone.sizeAllocated))"
                    + "/blocks=\(zone.blocksInUse)"
            }
        return [
            vmLine,
            Self.fit("regions: walked=\(regionsWalked)", entries: Array(regions)),
            Self.fit("malloc:", entries: Array(zones))
        ]
    }
}
