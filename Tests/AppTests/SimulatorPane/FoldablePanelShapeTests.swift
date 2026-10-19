// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import CoreGraphics
import Testing

/// A frame's own size decides which panel it is, once the hinge-spanning
/// panel's size is known; until then the daemon's report stands.
struct FoldablePanelShapeTests {
    private static let inner = CGSize(width: 2_007, height: 2_853)
    private static let cover = CGSize(width: 1_398, height: 2_034)

    @Test("the frame's size wins over the report once the spanning size is known", arguments: [
        (inner, false, true),
        (CGSize(width: 2_853, height: 2_007), false, true),
        (cover, true, false)
    ])
    func sizeDecides(surface: CGSize, reported: Bool, expected: Bool) {
        #expect(
            FoldablePanelShape.spansHinge(surfaceSize: surface, spanningPanelSize: Self.inner, reported: reported)
                == expected
        )
    }

    @Test("an unknown size on either side leaves the report standing", arguments: [
        (CGSize.zero, CGSize?.some(inner)),
        (cover, CGSize?.none),
        (cover, CGSize?.some(.zero))
    ])
    func unknownFallsBack(surface: CGSize, spanning: CGSize?) {
        for reported in [true, false] {
            #expect(
                FoldablePanelShape.spansHinge(surfaceSize: surface, spanningPanelSize: spanning, reported: reported)
                    == reported
            )
        }
    }
}
