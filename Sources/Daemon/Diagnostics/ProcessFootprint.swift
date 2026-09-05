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
        return UInt64(info.phys_footprint)
    }
}
