// SPDX-License-Identifier: GPL-3.0-or-later

/// Index arithmetic for the two zones of a window's tab array: pinned tabs
/// form a contiguous prefix and every unpinned tab follows them.
///
/// Every helper works on the array *without* the tab being placed, the same
/// post-removal indexing `TabListViewModel.move` uses, so an insertion index
/// means "insert before the tab currently at this index".
enum TabPinZoneMath {
    /// The insertion indices a tab may take. A pinned tab lands anywhere from
    /// the front up to the end of the pinned run; an unpinned tab anywhere from
    /// the end of the pinned run up to the end of the array.
    ///
    /// `pinnedOthers` and `totalOthers` count the tabs other than the one
    /// being placed.
    static func insertionRange(
        pinned: Bool,
        pinnedOthers: Int,
        totalOthers: Int
    ) -> ClosedRange<Int> {
        pinned ? 0...pinnedOthers : pinnedOthers...totalOthers
    }

    /// `index` pulled into `insertionRange`, so no placement can break the
    /// pinned prefix, however far outside the zone the caller asked for.
    static func clampedInsertion(
        _ index: Int,
        pinned: Bool,
        pinnedOthers: Int,
        totalOthers: Int
    ) -> Int {
        let range = insertionRange(pinned: pinned, pinnedOthers: pinnedOthers, totalOthers: totalOthers)
        return min(max(index, range.lowerBound), range.upperBound)
    }
}
