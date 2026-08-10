// SPDX-License-Identifier: GPL-3.0-or-later
//
// ScrollMods: pack the precision flag + scroll-momentum phase into
// the Int32 mods bitmask `ghostty_surface_mouse_scroll` expects as its
// third argument (`ghostty_input_scroll_mods_t`, defined as `int` in
// libghostty/ghostty.h).
//
// Wire layout (matches Ghostty.app's canonical SurfaceView_AppKit):
//   bit 0      : precision flag (1 = trackpad / Magic Mouse, 0 = wheel)
//   bits 1..3  : momentum phase enum
//                  0=NONE 1=BEGAN 2=STATIONARY 3=CHANGED
//                  4=ENDED 5=CANCELLED 6=MAY_BEGIN
//   bits 4..   : reserved (zero)
//
// Bits 1..3 are what makes inertial scrolling work. A mods value
// carrying only bit 0 reads as MOMENTUM_NONE, which libghostty takes
// to mean "no inertia", so a trackpad lift ends the scroll abruptly
// instead of coasting.
//
// Pure helper (no AppKit, no GhosttyKit) per AGENTS.md's
// "pure math namespaces / decision types" convention. The
// NSEvent.Phase → ScrollMomentum mapping lives in
// `ScrollMomentum+NSEvent.swift` (AppKit-bound).

enum ScrollMomentum: UInt8, Equatable {
    case none = 0
    case began = 1
    case stationary = 2
    case changed = 3
    case ended = 4
    case cancelled = 5
    case mayBegin = 6
}

enum ScrollMods {
    /// Pack the precision flag + momentum phase into the Int32 bitmask
    /// `ghostty_surface_mouse_scroll` expects as its `mods` argument.
    static func pack(precision: Bool, momentum: ScrollMomentum) -> Int32 {
        var value: Int32 = 0
        if precision { value |= 0b0000_0001 }
        value |= Int32(momentum.rawValue) << 1
        return value
    }
}
