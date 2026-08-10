// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
@testable import LibghosttyBridge
import Testing

// ScrollMods.pack(precision:momentum:) encodes a scroll event's
// metadata into the Int32 bitmask `ghostty_surface_mouse_scroll`
// expects as its third argument. Getting the bit layout wrong is the
// inertial-scroll regression: libghostty silently interprets a
// missing momentum phase as "no inertia" and disables coasting, so
// trackpad lifts feel abrupt. Tests pin the layout against
// Ghostty.app's canonical wire format.

// MARK: - ScrollMods.pack

@Test
func packsPrecisionOnly() {
    #expect(ScrollMods.pack(precision: false, momentum: .none) == 0)
    #expect(ScrollMods.pack(precision: true, momentum: .none) == 0b0000_0001)
}

@Test
func packsMomentumIntoBitsOneThroughThree() {
    #expect(ScrollMods.pack(precision: false, momentum: .began) == 0b0000_0010) // 1 << 1
    #expect(ScrollMods.pack(precision: false, momentum: .stationary) == 0b0000_0100) // 2 << 1
    #expect(ScrollMods.pack(precision: false, momentum: .changed) == 0b0000_0110) // 3 << 1
    #expect(ScrollMods.pack(precision: false, momentum: .ended) == 0b0000_1000) // 4 << 1
    #expect(ScrollMods.pack(precision: false, momentum: .cancelled) == 0b0000_1010) // 5 << 1
    #expect(ScrollMods.pack(precision: false, momentum: .mayBegin) == 0b0000_1100) // 6 << 1
}

@Test
func combinesPrecisionAndMomentum() {
    #expect(ScrollMods.pack(precision: true, momentum: .began) == 0b0000_0011)
    #expect(ScrollMods.pack(precision: true, momentum: .ended) == 0b0000_1001)
    #expect(ScrollMods.pack(precision: true, momentum: .mayBegin) == 0b0000_1101)
}

@Test
func unusedBitsStayZero() {
    // Bits 4 and above are reserved; nothing we encode should set them.
    let widest = ScrollMods.pack(precision: true, momentum: .mayBegin)
    #expect(widest & ~0b0000_1111 == 0)
}

// MARK: - ScrollMomentum.from(NSEvent.Phase)

@Test
func mapsKnownPhasesToMomentum() {
    #expect(ScrollMomentum.from(.began) == .began)
    #expect(ScrollMomentum.from(.stationary) == .stationary)
    #expect(ScrollMomentum.from(.changed) == .changed)
    #expect(ScrollMomentum.from(.ended) == .ended)
    #expect(ScrollMomentum.from(.cancelled) == .cancelled)
    #expect(ScrollMomentum.from(.mayBegin) == .mayBegin)
}

@Test
func mapsEmptyPhaseToNone() {
    // NSEvent.Phase is an OptionSet; between gestures it's the empty
    // set, which doesn't equal any of the named phases.
    #expect(ScrollMomentum.from([]) == .none)
}
