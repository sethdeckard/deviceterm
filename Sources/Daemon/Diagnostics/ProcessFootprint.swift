// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

/// The process's physical footprint as reported by `TASK_VM_INFO`.
///
/// `phys_footprint` rather than `resident_size`, because it is the number
/// macOS itself accounts against a process. It includes IOSurface and
/// compressed-memory accounting that `resident_size` may not represent
/// consistently.
enum ProcessFootprint {
    /// Bytes, or nil if the kernel refused the query. Callers log the absence
    /// rather than substituting a zero, since a zero would read as a healthy
    /// sample.
    static func physFootprintBytes() -> UInt64? {
        vmInfo()?.physFootprint
    }

    /// The whole reading, or nil if the kernel refused the query.
    ///
    /// `count` asks for the full structure. The kernel fills as much of it as
    /// its revision knows and reports how much it wrote, which is what gates
    /// the optional fields: a field is present only when the written length
    /// covers it.
    static func vmInfo() -> TaskVMInfoSummary? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let writtenBytes = Int(count) * MemoryLayout<natural_t>.size
        func present<Value>(_ keyPath: KeyPath<task_vm_info_data_t, Value>) -> Bool {
            guard let offset = MemoryLayout<task_vm_info_data_t>.offset(of: keyPath) else {
                return false
            }
            return offset + MemoryLayout<Value>.size <= writtenBytes
        }
        return TaskVMInfoSummary(
            physFootprint: UInt64(info.phys_footprint),
            physFootprintPeak: clamped(info.ledger_phys_footprint_peak),
            resident: UInt64(info.resident_size),
            internalBytes: UInt64(info.internal),
            external: UInt64(info.external),
            reusable: UInt64(info.reusable),
            compressed: UInt64(info.compressed),
            compressedPeak: UInt64(info.compressed_peak),
            purgeableVolatileResident: UInt64(info.purgeable_volatile_resident),
            purgeableNonvolatile: clamped(info.ledger_purgeable_nonvolatile),
            graphicsFootprint: clamped(info.ledger_tag_graphics_footprint),
            mediaFootprint: clamped(info.ledger_tag_media_footprint),
            networkNonvolatile: clamped(info.ledger_tag_network_nonvolatile),
            regionCount: Int(info.region_count),
            pageSize: Int(info.page_size),
            limitBytesRemaining: present(\.limit_bytes_remaining)
                ? UInt64(info.limit_bytes_remaining) : nil,
            decompressions: present(\.decompressions) ? Int(info.decompressions) : nil,
            swapins: present(\.ledger_swapins) ? Int(info.ledger_swapins) : nil
        )
    }

    /// Ledger fields are signed; a negative reading is an accounting
    /// artifact and reads as zero.
    private static func clamped(_ value: Int64) -> UInt64 {
        UInt64(max(0, value))
    }
}
