// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The process's `TASK_VM_INFO` reading, reduced to the fields that say where
/// a footprint sits.
///
/// `physFootprint` is the number macOS accounts against the process. The other
/// fields are related counters, not an additive partition of it:
/// `internalBytes` is anonymous memory the process dirtied, `compressed` the
/// part of that the compressor holds, `external` is file-backed, `reusable` is
/// freed-but-mapped malloc memory, and the ledger tags name memory the kernel
/// attributes to graphics, media, and network allocators on the process's
/// behalf. The optional fields exist only in newer
/// revisions of the kernel structure and are nil when the kernel filled a
/// shorter one.
struct TaskVMInfoSummary: Sendable, Equatable {
    var physFootprint: UInt64
    var physFootprintPeak: UInt64
    var resident: UInt64
    var internalBytes: UInt64
    var external: UInt64
    var reusable: UInt64
    var compressed: UInt64
    var compressedPeak: UInt64
    var purgeableVolatileResident: UInt64
    var purgeableNonvolatile: UInt64
    var graphicsFootprint: UInt64
    var mediaFootprint: UInt64
    var networkNonvolatile: UInt64
    var regionCount: Int
    var pageSize: Int
    var limitBytesRemaining: UInt64?
    var decompressions: Int?
    var swapins: Int?

    /// One `key=value` line in MiB, in the style of the footprint sample.
    var line: String {
        var fields = [
            "vm: phys=\(Self.mib(physFootprint))",
            "peak=\(Self.mib(physFootprintPeak))",
            "resident=\(Self.mib(resident))",
            "internal=\(Self.mib(internalBytes))",
            "external=\(Self.mib(external))",
            "compressed=\(Self.mib(compressed))",
            "compressedPeak=\(Self.mib(compressedPeak))",
            "purgeableVolatile=\(Self.mib(purgeableVolatileResident))",
            "purgeableNonvolatile=\(Self.mib(purgeableNonvolatile))",
            "graphics=\(Self.mib(graphicsFootprint))",
            "media=\(Self.mib(mediaFootprint))",
            "network=\(Self.mib(networkNonvolatile))",
            "reusable=\(Self.mib(reusable))",
            "regions=\(regionCount)",
            "pageSize=\(pageSize)"
        ]
        if let limitBytesRemaining {
            fields.append("limitRemaining=\(Self.mib(limitBytesRemaining))")
        }
        if let decompressions {
            fields.append("decompressions=\(decompressions)")
        }
        if let swapins {
            fields.append("swapins=\(swapins)")
        }
        return fields.joined(separator: " ")
    }

    static func mib(_ bytes: UInt64) -> String {
        "\(bytes / 1_048_576)MiB"
    }
}
