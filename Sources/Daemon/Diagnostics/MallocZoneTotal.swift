// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One malloc zone's statistics, as libmalloc reports them.
///
/// `sizeInUse` is what the zone's live blocks occupy; `sizeAllocated` is
/// what the zone holds from the VM, including freed blocks it has not
/// returned. A large gap between the two is capacity the allocator kept,
/// often fragmentation; it says nothing about whether the live blocks are
/// leaked.
struct MallocZoneTotal: Sendable, Equatable {
    var name: String
    var blocksInUse: Int
    var sizeInUse: UInt64
    var maxSizeInUse: UInt64
    var sizeAllocated: UInt64
}
