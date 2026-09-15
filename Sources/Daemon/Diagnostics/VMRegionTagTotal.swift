// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Every mapped region carrying one VM memory tag, summed.
///
/// The tag is what the mapper stamped on the region: an allocator, a
/// subsystem, or a kind of mapping such as stacks or dylibs. A total per tag
/// says which category dominates without naming any one allocation.
struct VMRegionTagTotal: Sendable, Equatable {
    var tag: UInt32
    var regions: Int
    var virtualBytes: UInt64
    var residentBytes: UInt64
    var dirtyBytes: UInt64
    /// Bytes the compressor holds for these regions. A footprint that grows
    /// while resident memory does not is growing here.
    var compressedBytes: UInt64

    var name: String { VMMemoryTag.name(tag) }

    /// What the tag contributes to the process footprint: dirty pages in
    /// memory plus the pages the compressor holds.
    var footprintBytes: UInt64 { dirtyBytes + compressedBytes }
}
