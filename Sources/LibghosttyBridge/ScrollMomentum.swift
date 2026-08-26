// SPDX-License-Identifier: GPL-3.0-or-later

/// The scroll-momentum phase libghostty encodes in bits 1..3
/// of `ghostty_input_scroll_mods_t`. Raw values match that wire encoding.
///
/// Pure (no AppKit, no GhosttyKit). The NSEvent.Phase → ScrollMomentum
/// mapping lives in `ScrollMomentum+NSEvent.swift` (AppKit-bound), and the
/// packing into the mods bitmask lives in `ScrollMods.swift`.
enum ScrollMomentum: UInt8, Equatable {
    case none = 0
    case began = 1
    case stationary = 2
    case changed = 3
    case ended = 4
    case cancelled = 5
    case mayBegin = 6
}
