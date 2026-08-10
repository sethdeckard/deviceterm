// SPDX-License-Identifier: GPL-3.0-or-later

@testable import LibghosttyBridge
import Testing

// ColorLuma classifies an sRGB triple as "light" or "dark" so
// `SurfaceScrollView` can pick a contrasting scroller appearance.
// The 0.5 threshold + the 0.299/0.587/0.114 weights are the well-
// known NTSC / Rec.601 relative-luminance formula; these tests
// pin the threshold + the weight ordering (G dominates, B is
// least) against the canonical light/dark colors a terminal
// theme is likely to use.

@Test
func pureBlackIsDark() {
    #expect(!ColorLuma.isLight(red: 0, green: 0, blue: 0))
}

@Test
func pureWhiteIsLight() {
    #expect(ColorLuma.isLight(red: 255, green: 255, blue: 255))
}

@Test
func midGrayIsLight() {
    // 128/255 ≈ 0.502; the threshold is "at or above 0.5", so
    // mid-gray classifies as light (the bright-side of the curve).
    #expect(ColorLuma.isLight(red: 128, green: 128, blue: 128))
}

@Test
func defaultGhosttyDarkBackgroundIsDark() {
    // Ghostty's stock dark theme bg is roughly #1d1f21 (28, 31, 33),
    // below the 0.5 threshold, so it picks .darkAqua (light scroller).
    #expect(!ColorLuma.isLight(red: 28, green: 31, blue: 33))
}

@Test
func solarizedLightBackgroundIsLight() {
    // Solarized Light bg is #fdf6e3 (253, 246, 227), above 0.5, so it
    // picks .aqua (dark scroller).
    #expect(ColorLuma.isLight(red: 253, green: 246, blue: 227))
}

@Test
func pureGreenIsLightDespiteRedAndBlueDark() {
    // Green is weighted 0.587, so by itself at full intensity it
    // crosses 0.5 (luma ≈ 0.587). Catches the case where someone
    // refactors to equal-weight average and breaks the perceptual
    // brightness ordering (R+G+B / 3 would give 85 → false here).
    #expect(ColorLuma.isLight(red: 0, green: 255, blue: 0))
}

@Test
func pureBlueIsDarkDespiteFullIntensity() {
    // Blue is weighted 0.114, so at full intensity its luma is only
    // ~0.114, well below 0.5. Pins the weight ordering: blue
    // contributes the least to perceived brightness.
    #expect(!ColorLuma.isLight(red: 0, green: 0, blue: 255))
}

@Test
func pureRedIsDarkDespiteFullIntensity() {
    // Red is weighted 0.299, so at full intensity its luma is ~0.299,
    // below 0.5. Pins R weight < G weight.
    #expect(!ColorLuma.isLight(red: 255, green: 0, blue: 0))
}

@Test
func atExactThresholdIsLight() {
    // The "at or above 0.5" boundary: a triple whose luma lands
    // exactly on 0.5 should classify light. 128 × 0.299 + 128 ×
    // 0.587 + 128 × 0.114 = 128 × 1.0 = 128 → 128/255 ≈ 0.502,
    // which is >= 0.5. Encodes the inclusive lower bound.
    #expect(ColorLuma.isLight(red: 128, green: 128, blue: 128))
}
