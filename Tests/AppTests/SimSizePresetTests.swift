// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimSizePresetTests: pure math for the four sim-pane size presets.
// The chrome ribbon's Size dropdown and the View menu's ⌃⌘1–⌃⌘4 both
// call `SimSizeMath.targetWidth`, so pinning the per-case math here
// covers both surfaces.
//
// Each case has its own assertion shape:
//   - `.fitScreen`: always returns the available width.
//   - `.pixelAccurate`: width = pixelWidth / Mac backing scale.
//   - `.pointAccurate`: width = pixelWidth / device @x scale (family-derived).
//   - `.physical`: width = (pixelWidth / device PPI) × Mac PPI.
//   - Nil dimensions → nil (caller falls back to family-default).

@testable import App
import CoreGraphics
import DaemonProtocol
import Testing

@MainActor
struct SimSizePresetTests {
    private let iPhone = SimDeviceMetrics(
        pixelWidth: 1_206,
        pixelHeight: 2_622,
        family: .phone
    )
    private let watch = SimDeviceMetrics(
        pixelWidth: 502,
        pixelHeight: 612,
        family: .watch
    )
    private let mac = MacScreenMetrics(
        backingScaleFactor: 2.0,
        pointsPerInch: 110
    )

    @Test
    func fitScreenFallsBackToAvailableWhenPerpendicularUnknown() {
        // Without a perpendicular extent (initial layout / 0-sized
        // pane), Fit Screen can't compute an aspect-matched target,
        // so it returns `availableWidth` as a no-divergence no-op.
        let result = SimSizeMath.targetWidth(
            preset: .fitScreen,
            device: iPhone,
            screen: mac,
            availableWidth: 640
        )
        #expect(result == 640)
    }

    @Test
    func fitScreenWidthIsHeightTimesDeviceAspectInVerticalSplit() {
        // Side-by-side split: divider runs vertically, sizing the
        // pane's WIDTH against a fixed HEIGHT. With no bezel
        // reserve the screen fills the perpendicular extent:
        // 600 × (1206/2622) ≈ 276.0.
        let result = SimSizeMath.targetWidth(
            preset: .fitScreen,
            device: iPhone,
            screen: mac,
            availableWidth: 1_000,
            axisIsVertical: true,
            perpendicularExtent: 600
        )
        let expected = 600.0 * (1_206.0 / 2_622.0)
        #expect(result != nil)
        if let result {
            #expect(abs(result - expected) < 0.001)
        }
    }

    @Test
    func fitScreenHeightIsWidthDividedByDeviceAspectInHorizontalSplit() {
        // Top/bottom split: divider runs horizontally, sizing the
        // pane's HEIGHT against a fixed WIDTH. Target = width ÷
        // (deviceWidth / deviceHeight) = width × (deviceHeight /
        // deviceWidth). For iPhone in a 600pt-wide pane:
        // 600 × (2622/1206) ≈ 1304.5.
        let result = SimSizeMath.targetWidth(
            preset: .fitScreen,
            device: iPhone,
            screen: mac,
            availableWidth: 2_000,
            axisIsVertical: false,
            perpendicularExtent: 600
        )
        let expected = 600.0 * (2_622.0 / 1_206.0)
        #expect(result != nil)
        if let result {
            #expect(abs(result - expected) < 0.001)
        }
    }

    @Test
    func fitScreenIsClampedToAvailableWidth() {
        // Aspect math would overflow the available extent → clamp.
        // 1000 × (1206/2622) ≈ 460; available is 400, so 400.
        let result = SimSizeMath.targetWidth(
            preset: .fitScreen,
            device: iPhone,
            screen: mac,
            availableWidth: 400,
            axisIsVertical: true,
            perpendicularExtent: 1_000
        )
        #expect(result == 400)
    }

    @Test
    func fitScreenSwapsAspectWhenLandscape() {
        // iPhone 1206×2622 in a 600pt-tall pane, rotated to
        // landscapeLeft. The displayed aspect becomes
        // (2622/1206), which is wide, so the target width is
        // 600 × (2622/1206) ≈ 1304.5, NOT the portrait 276.
        let result = SimSizeMath.targetWidth(
            preset: .fitScreen,
            device: iPhone,
            screen: mac,
            availableWidth: 2_000,
            axisIsVertical: true,
            perpendicularExtent: 600,
            orientation: .landscapeLeft
        )
        let expected = 600.0 * (2_622.0 / 1_206.0)
        #expect(result != nil)
        if let result {
            #expect(abs(result - expected) < 0.001)
        }
    }

    @Test
    func pixelAccurateAddsBezelReserveToTarget() {
        // The shader subtracts `displayInset` on both sides before
        // drawing the screen, so a Pixel Accurate pane has to be
        // wider than the raw `pixelExtent / backing`, or else
        // the visible (rendered) screen ends up smaller than the
        // device pixel count. 1206/2 = 603 pixels screen + 32pt
        // bezel reserve = 635pt pane.
        let result = SimSizeMath.targetWidth(
            preset: .pixelAccurate,
            device: iPhone,
            screen: mac,
            availableWidth: 1_000,
            bezelReserve: 16
        )
        #expect(result == CGFloat(603 + 32))
    }

    @Test
    func pointAccurateAddsBezelReserveToTarget() {
        let result = SimSizeMath.targetWidth(
            preset: .pointAccurate,
            device: iPhone,
            screen: mac,
            availableWidth: 1_000,
            bezelReserve: 16
        )
        #expect(result == CGFloat(402 + 32))
    }

    @Test
    func physicalAddsBezelReserveToTarget() {
        let result = SimSizeMath.targetWidth(
            preset: .physical,
            device: iPhone,
            screen: mac,
            availableWidth: 10_000,
            bezelReserve: 16
        )
        let inches = 1_206.0 / SimSizeMath.devicePixelsPerInch(family: .phone)
        let expected = inches * 110 + 32
        #expect(result != nil)
        if let result {
            #expect(abs(result - expected) < 0.001)
        }
    }

    @Test
    func fitScreenReservesBezelRoomOnPerpendicular() {
        // 600pt pane height, 16pt bezel reserve on each edge →
        // screen height = 568pt. Target width = 568 × aspect +
        // 2×16 (reserve added back so final pane width covers
        // screen + bezel). For iPhone: 568 × (1206/2622) ≈ 261.3,
        // plus 32 ≈ 293.3.
        let result = SimSizeMath.targetWidth(
            preset: .fitScreen,
            device: iPhone,
            screen: mac,
            availableWidth: 1_000,
            axisIsVertical: true,
            perpendicularExtent: 600,
            bezelReserve: 16
        )
        let screenHeight = 600.0 - 2 * 16.0
        let expected = screenHeight * (1_206.0 / 2_622.0) + 2 * 16.0
        #expect(result != nil)
        if let result {
            #expect(abs(result - expected) < 0.001)
        }
    }

    @Test
    func pixelAccurateMapsOnePixelToOneMacPixel() {
        let result = SimSizeMath.targetWidth(
            preset: .pixelAccurate,
            device: iPhone,
            screen: mac,
            availableWidth: 1_000
        )
        // 1_206 / 2.0 = 603
        #expect(result == 603)
    }

    @Test
    func pixelAccurateUsesPixelHeightInHorizontalSplit() {
        // After Toggle Split Direction the panes stack top/bottom, so the
        // preset must size against `pixelHeight` (the long axis on a
        // portrait device) or the pane ends up too short by the
        // aspect ratio. 2_622 / 2.0 = 1_311.
        let result = SimSizeMath.targetWidth(
            preset: .pixelAccurate,
            device: iPhone,
            screen: mac,
            availableWidth: 1_000,
            axisIsVertical: false
        )
        #expect(result == 1_311)
    }

    @Test
    func pointAccurateUsesPixelHeightInHorizontalSplit() {
        // 2_622 / 3.0 (phone @3x default) = 874.
        let result = SimSizeMath.targetWidth(
            preset: .pointAccurate,
            device: iPhone,
            screen: mac,
            availableWidth: 1_000,
            axisIsVertical: false
        )
        #expect(result == 874)
    }

    @Test
    func pixelAccurateClampsBackingFactorBelowOne() {
        // A malformed screen metric (backing < 1) shouldn't divide-by-
        // zero or produce a width larger than the pixel count; the
        // implementation clamps the factor to at least 1.0.
        let bad = MacScreenMetrics(backingScaleFactor: 0, pointsPerInch: 110)
        let result = SimSizeMath.targetWidth(
            preset: .pixelAccurate,
            device: iPhone,
            screen: bad,
            availableWidth: 1_000
        )
        #expect(result == 1_206)
    }

    @Test
    func pointAccuratePhoneUsesAt3x() {
        // Phone defaults to @3x; 1_206 / 3 = 402.
        let result = SimSizeMath.targetWidth(
            preset: .pointAccurate,
            device: iPhone,
            screen: mac,
            availableWidth: 1_000
        )
        #expect(result == 402)
    }

    @Test
    func pointAccurateWatchUsesAt2x() {
        // Watch defaults to @2x; 502 / 2 = 251.
        let result = SimSizeMath.targetWidth(
            preset: .pointAccurate,
            device: watch,
            screen: mac,
            availableWidth: 1_000
        )
        #expect(result == 251)
    }

    @Test
    func physicalSizePhoneApproximatesRealInches() {
        // Phone PPI ≈ 460; 1_206 / 460 ≈ 2.622 inches; at 110 Mac PPI
        // ≈ 288 points. Wide tolerance because the PPI baseline is an
        // approximation; we just want the order-of-magnitude check.
        let result = SimSizeMath.targetWidth(
            preset: .physical,
            device: iPhone,
            screen: mac,
            availableWidth: 1_000
        )
        #expect(result != nil)
        let value = result ?? 0
        #expect(value > 250 && value < 320)
    }

    @Test
    func physicalSizeWatchProducesSmallerWidth() {
        // Watch ≈ 502 / 326 ≈ 1.54 inches × 110 ≈ 169.5, so sanity-check
        // tighter bounds.
        let result = SimSizeMath.targetWidth(
            preset: .physical,
            device: watch,
            screen: mac,
            availableWidth: 1_000
        )
        let value = result ?? 0
        #expect(value > 140 && value < 200)
    }

    @Test
    func nilWhenPixelDimensionsAreMissing() {
        // Renderable not bound yet, so the daemon emits 0 / 0 pixel sizes;
        // every preset returns nil so the caller falls back to the
        // existing split layout.
        let missing = SimDeviceMetrics(pixelWidth: 0, pixelHeight: 0, family: .phone)
        for preset in SimSizePreset.allCases {
            let result = SimSizeMath.targetWidth(
                preset: preset,
                device: missing,
                screen: mac,
                availableWidth: 1_000
            )
            #expect(result == nil, "preset \(preset.rawValue) should be nil")
        }
    }

    @Test
    func deviceScaleDefaultsByFamily() {
        #expect(SimSizeMath.deviceScale(family: .watch) == 2.0)
        #expect(SimSizeMath.deviceScale(family: .phone) == 3.0)
        #expect(SimSizeMath.deviceScale(family: .pad) == 2.0)
        #expect(SimSizeMath.deviceScale(family: .tv) == 1.0)
        #expect(SimSizeMath.deviceScale(family: .unknown) == 1.0)
    }

    @Test
    func displayNamesMatchAppleSimulatorVocabulary() {
        // The displayed labels match Apple's Simulator.app Window
        // submenu vocabulary so a user moving from that app finds the
        // same names here. A drift breaks the matching menu line.
        #expect(SimSizePreset.physical.displayName == "Physical Size")
        #expect(SimSizePreset.pointAccurate.displayName == "Point Accurate")
        #expect(SimSizePreset.pixelAccurate.displayName == "Pixel Accurate")
        #expect(SimSizePreset.fitScreen.displayName == "Fit Screen")
    }
}
