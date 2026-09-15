// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Names for the VM memory tags allocators stamp on their regions.
///
/// The values are the `VM_MEMORY_*` constants from `mach/vm_statistics.h`,
/// spelled the way `vmmap` prints them so a breakdown line reads like one of
/// its summaries. Tag 0 is what `mach_vm_allocate` leaves on an untagged
/// region, which `vmmap` reports as `VM_ALLOCATE`.
enum VMMemoryTag {
    private static let names: [UInt32: String] = [
        0: "VM_ALLOCATE",
        1: "MALLOC",
        2: "MALLOC_SMALL",
        3: "MALLOC_LARGE",
        4: "MALLOC_HUGE",
        6: "REALLOC",
        7: "MALLOC_TINY",
        8: "MALLOC_LARGE_REUSABLE",
        9: "MALLOC_LARGE_REUSED",
        10: "ANALYSIS_TOOL",
        11: "MALLOC_NANO",
        12: "MALLOC_MEDIUM",
        13: "MALLOC_PROB_GUARD",
        20: "MACH_MSG",
        21: "IOKIT",
        22: "VM_RECLAIM",
        30: "STACK",
        31: "GUARD",
        32: "SHARED_PMAP",
        33: "DYLIB",
        34: "OBJC_DISPATCHERS",
        35: "UNSHARED_PMAP",
        40: "APPKIT",
        41: "FOUNDATION",
        42: "COREGRAPHICS",
        43: "CORESERVICES",
        45: "COREDATA",
        51: "LAYERKIT",
        52: "CGIMAGE",
        54: "COREGRAPHICS_DATA",
        55: "COREGRAPHICS_SHARED",
        56: "COREGRAPHICS_FRAMEBUFFERS",
        57: "COREGRAPHICS_BACKINGSTORES",
        58: "COREGRAPHICS_XALLOC",
        60: "DYLD",
        61: "DYLD_MALLOC",
        62: "SQLITE",
        68: "COREIMAGE",
        70: "IMAGEIO",
        73: "OS_ALLOC_ONCE",
        74: "LIBDISPATCH",
        76: "COREUI",
        82: "SWIFT_RUNTIME",
        83: "SWIFT_METADATA",
        87: "SKYWALK",
        88: "IOSURFACE",
        89: "LIBNETWORK",
        92: "CM_XPC",
        100: "IOACCELERATOR"
    ]

    /// The range Apple reserves for application-specific tags.
    private static let applicationSpecific: ClosedRange<UInt32> = 240 ... 255

    static func name(_ tag: UInt32) -> String {
        if let name = names[tag] {
            return name
        }
        if applicationSpecific.contains(tag) {
            return "APP_SPECIFIC_\(tag - applicationSpecific.lowerBound + 1)"
        }
        return "tag\(tag)"
    }
}
