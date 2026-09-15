// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

/// Reads the process's own memory breakdown in-process.
///
/// In-process because the daemon runs with the hardened runtime and no
/// debugging entitlement, so `vmmap` and `heap` cannot reliably attach to it,
/// while inspecting the current process needs no attach. The region walk
/// makes a Mach call for each visited region or submap, so it runs only when
/// a reading is worth explaining, never on a cadence.
///
/// Every raw pointer here stays inside a synchronous call and only value types
/// come out, which is what lets an actor call this without any hand-off.
enum MemoryBreakdownReader {
    static func read() -> MemoryBreakdown {
        let vmInfo = ProcessFootprint.vmInfo()
        // The task's own page size. The `vm_page_size` global is not
        // concurrency-safe to read under strict checking.
        let pageSize = vmInfo?.pageSize ?? Int(sysconf(Int32(_SC_PAGESIZE)))
        let regions = regionTotals(pageSize: pageSize)
        return MemoryBreakdown(
            vmInfo: vmInfo,
            regionTotals: regions.totals,
            regionsWalked: regions.walked,
            mallocZones: mallocZoneTotals()
        )
    }

    /// Walk every mapped region, descending into submaps, and sum by tag.
    static func regionTotals(pageSize: Int) -> (totals: [VMRegionTagTotal], walked: Int) {
        var totals: [UInt32: VMRegionTagTotal] = [:]
        var walked = 0
        var address: mach_vm_address_t = 0
        var depth: natural_t = 0
        let page = UInt64(max(pageSize, 1))
        while true {
            var size: mach_vm_size_t = 0
            var info = vm_region_submap_info_data_64_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<natural_t>.size
            )
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                    mach_vm_region_recurse(mach_task_self_, &address, &size, &depth, rebound, &count)
                }
            }
            guard result == KERN_SUCCESS else { break }
            if info.is_submap != 0 {
                // Re-query the same address one level down, the way `vmmap`
                // does, so the submap's contents are counted, not its shell.
                depth += 1
                continue
            }
            walked += 1
            var total = totals[info.user_tag] ?? VMRegionTagTotal(
                tag: info.user_tag,
                regions: 0,
                virtualBytes: 0,
                residentBytes: 0,
                dirtyBytes: 0,
                compressedBytes: 0
            )
            total.regions += 1
            total.virtualBytes += UInt64(size)
            total.residentBytes += UInt64(info.pages_resident) * page
            total.dirtyBytes += UInt64(info.pages_dirtied) * page
            total.compressedBytes += UInt64(info.pages_swapped_out) * page
            totals[info.user_tag] = total
            let next = address &+ size
            guard next > address else { break }
            address = next
        }
        return (Array(totals.values), walked)
    }

    /// Statistics for every malloc zone in the process. The zone table is
    /// libmalloc's; it is read, never freed.
    static func mallocZoneTotals() -> [MallocZoneTotal] {
        var addresses: UnsafeMutablePointer<vm_address_t>?
        var count: UInt32 = 0
        guard malloc_get_all_zones(mach_task_self_, nil, &addresses, &count) == KERN_SUCCESS,
            let addresses
        else { return [] }
        var zones: [MallocZoneTotal] = []
        for index in 0 ..< Int(count) {
            guard let zone = UnsafeMutablePointer<malloc_zone_t>(bitPattern: UInt(addresses[index])) else {
                continue
            }
            var stats = malloc_statistics_t()
            malloc_zone_statistics(zone, &stats)
            let name = malloc_get_zone_name(zone).map { String(cString: $0) } ?? "zone\(index)"
            zones.append(
                MallocZoneTotal(
                    name: name,
                    blocksInUse: Int(stats.blocks_in_use),
                    sizeInUse: UInt64(stats.size_in_use),
                    maxSizeInUse: UInt64(stats.max_size_in_use),
                    sizeAllocated: UInt64(stats.size_allocated)
                )
            )
        }
        return zones
    }
}
