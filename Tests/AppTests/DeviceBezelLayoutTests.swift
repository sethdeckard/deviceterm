// SPDX-License-Identifier: GPL-3.0-or-later
//
// DeviceBezelLayoutTests: pure-math pins for the per-family bezel
// geometry the wrapper paints around the sim screen. Each family has
// its own assertion shape:
//
//   - phone → bezel rect insetting `imageRect`, notch rect at top
//     center, no crown.
//   - pad → bezel rect, no notch, no crown.
//   - watch → bezel + crown rect on the trailing (right) edge, no
//     notch.
//   - tv → layout is nil (no bezel painted; letterbox stays as-is).
//   - unknown → falls back to the phone style.
//
// The bezel inset + corner radius scale with the smaller imageRect
// dimension and are clamped to a reasonable range; these tests pin
// the boundary behavior so a future scale tweak can't accidentally
// produce a 1pt-thick bezel or a square-cornered phone.

@testable import App
import CoreGraphics
import DaemonProtocol
import Testing

struct DeviceBezelLayoutTests {
    private let screenRect = CGRect(x: 100, y: 50, width: 200, height: 400)

    @Test
    func phoneHasBezelAndNotchNoCrown() throws {
        let layout = try #require(
            DeviceBezelLayoutMath.layout(family: .phone, imageRect: screenRect)
        )
        // Bezel insets outward from the image rect.
        #expect(layout.bezelRect.origin.x < screenRect.origin.x)
        #expect(layout.bezelRect.origin.y < screenRect.origin.y)
        #expect(layout.bezelRect.maxX > screenRect.maxX)
        #expect(layout.bezelRect.maxY > screenRect.maxY)
        // Phone has a notch, not a crown.
        #expect(layout.notchRect != nil)
        #expect(layout.crownRect == nil)
        // Notch sits at the top of the image rect, centered.
        let notch = try #require(layout.notchRect)
        #expect(abs(notch.midX - screenRect.midX) < 1e-6)
        #expect(notch.minY == screenRect.minY)
    }

    @Test
    func padHasBezelButNoNotchOrCrown() throws {
        let layout = try #require(
            DeviceBezelLayoutMath.layout(family: .pad, imageRect: screenRect)
        )
        #expect(layout.notchRect == nil)
        #expect(layout.crownRect == nil)
        // Pad bezel is thinner than phone, asserted via comparison
        // on the same image rect.
        let phone = try #require(
            DeviceBezelLayoutMath.layout(family: .phone, imageRect: screenRect)
        )
        let phoneInset = screenRect.minX - phone.bezelRect.minX
        let padInset = screenRect.minX - layout.bezelRect.minX
        #expect(padInset < phoneInset)
    }

    @Test
    func watchHasBezelAndCrownOnRightEdge() throws {
        let layout = try #require(
            DeviceBezelLayoutMath.layout(family: .watch, imageRect: screenRect)
        )
        #expect(layout.notchRect == nil)
        let crown = try #require(layout.crownRect)
        // Crown straddles the bezel's right edge, so midX matches
        // the bezel's max x.
        #expect(abs(crown.midX - layout.bezelRect.maxX) < 1e-6)
        // Vertically centered on the image rect.
        #expect(abs(crown.midY - screenRect.midY) < 1e-6)
        // Watch corner radius is large (squircle-ish), bigger
        // than phone's at the same screen size.
        let phone = try #require(
            DeviceBezelLayoutMath.layout(family: .phone, imageRect: screenRect)
        )
        #expect(layout.cornerRadius > phone.cornerRadius)
    }

    @Test
    func tvProducesNoBezelLayout() {
        #expect(
            DeviceBezelLayoutMath.layout(family: .tv, imageRect: screenRect) == nil
        )
    }

    @Test
    func unknownFallsBackToPhone() throws {
        let unknown = try #require(
            DeviceBezelLayoutMath.layout(family: .unknown, imageRect: screenRect)
        )
        let phone = try #require(
            DeviceBezelLayoutMath.layout(family: .phone, imageRect: screenRect)
        )
        #expect(unknown.bezelRect == phone.bezelRect)
        #expect(unknown.cornerRadius == phone.cornerRadius)
        #expect(unknown.notchRect == phone.notchRect)
    }

    @Test
    func degenerateImageRectReturnsNil() {
        #expect(
            DeviceBezelLayoutMath.layout(family: .phone, imageRect: .zero) == nil
        )
    }

    @Test
    func smallScreenClampsToMinimumBezel() throws {
        // 50×50 phone screen: scaled-by-ratio inset would be ~2pt;
        // the 8pt floor kicks in so the bezel is still readable.
        let tiny = CGRect(x: 0, y: 0, width: 50, height: 50)
        let layout = try #require(
            DeviceBezelLayoutMath.layout(family: .phone, imageRect: tiny)
        )
        let inset = tiny.minX - layout.bezelRect.minX
        #expect(inset >= 8)
    }

    @Test
    func largeScreenClampsToMaximumBezel() throws {
        // 2000×2000 phone screen: scaled-by-ratio inset would be
        // ~90pt; the 16pt ceiling clamps so a maxed-out pane doesn't
        // look like a picture frame.
        let huge = CGRect(x: 0, y: 0, width: 2_000, height: 2_000)
        let layout = try #require(
            DeviceBezelLayoutMath.layout(family: .phone, imageRect: huge)
        )
        let inset = huge.minX - layout.bezelRect.minX
        #expect(inset <= 16)
    }
}
