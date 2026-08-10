// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import InteractionRelay

/// The normalised 0…1 → device uint16 touch mapping, with clamping.
struct TouchScaleTests {
    @Test("the endpoints map to the full device range")
    func endpoints() {
        #expect(TouchScale.native(0) == 0)
        #expect(TouchScale.native(1) == 65_535)
    }

    @Test("the midpoint maps to the range centre")
    func midpoint() {
        #expect(TouchScale.native(0.5) == 32_767) // 0.5 * 65535 = 32767.5, truncated
    }

    @Test("out-of-range input is clamped, not wrapped")
    func clamping() {
        #expect(TouchScale.native(-0.5) == 0)
        #expect(TouchScale.native(1.5) == 65_535)
    }
}
