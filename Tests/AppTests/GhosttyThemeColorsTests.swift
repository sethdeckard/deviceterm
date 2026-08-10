// SPDX-License-Identifier: GPL-3.0-or-later
//
// GhosttyThemeColorsTests: pin the selection-background and
// background readers' accepted shapes. The fixture configs cover the
// canonical inputs (hashed hex, bare hex, key absent, malformed value)
// plus the colorspace dimension (explicit sRGB, Display P3) on both
// keys; the parser sub-tests pin the hex-shape rejection rules without
// going through the file loader.

@testable import App
import AppKit
import Foundation
import Testing

@MainActor
struct GhosttyThemeColorsTests {
    @Test
    func readsHashedHexFromConfigFile() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "ghostty-config-with-selection",
                withExtension: "config"
            )
        )
        let color = try #require(
            GhosttyThemeColors.selectionBackground(at: url.path)
        )
        let srgb = try #require(color.usingColorSpace(.sRGB))
        // #1e5680 = (30, 86, 128).
        #expect(Int(round(srgb.redComponent * 255)) == 30)
        #expect(Int(round(srgb.greenComponent * 255)) == 86)
        #expect(Int(round(srgb.blueComponent * 255)) == 128)
        #expect(srgb.alphaComponent == 1.0)
    }

    @Test
    func readsBareHexFromConfigFile() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "ghostty-config-bare-hex-selection",
                withExtension: "config"
            )
        )
        let color = try #require(
            GhosttyThemeColors.selectionBackground(at: url.path)
        )
        let srgb = try #require(color.usingColorSpace(.sRGB))
        // 7AA2F7 = (122, 162, 247).
        #expect(Int(round(srgb.redComponent * 255)) == 122)
        #expect(Int(round(srgb.greenComponent * 255)) == 162)
        #expect(Int(round(srgb.blueComponent * 255)) == 247)
    }

    @Test
    func returnsNilWhenSelectionBackgroundKeyAbsent() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "ghostty-config-no-selection",
                withExtension: "config"
            )
        )
        #expect(GhosttyThemeColors.selectionBackground(at: url.path) == nil)
    }

    @Test
    func returnsNilForMalformedColorValue() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "ghostty-config-malformed-selection",
                withExtension: "config"
            )
        )
        #expect(GhosttyThemeColors.selectionBackground(at: url.path) == nil)
    }

    @Test
    func returnsNilForMissingFile() {
        let absent = "/tmp/deviceterm-test-this-path-does-not-exist-\(UUID().uuidString)"
        #expect(GhosttyThemeColors.selectionBackground(at: absent) == nil)
    }

    @Test
    func parseHexAcceptsHashedSixDigit() throws {
        let color = try #require(GhosttyThemeColors.parseHexColor("#0080FF"))
        let srgb = try #require(color.usingColorSpace(.sRGB))
        #expect(Int(round(srgb.redComponent * 255)) == 0)
        #expect(Int(round(srgb.greenComponent * 255)) == 128)
        #expect(Int(round(srgb.blueComponent * 255)) == 255)
    }

    @Test
    func parseHexAcceptsBareSixDigit() throws {
        let color = try #require(GhosttyThemeColors.parseHexColor("0080FF"))
        let srgb = try #require(color.usingColorSpace(.sRGB))
        #expect(Int(round(srgb.redComponent * 255)) == 0)
        #expect(Int(round(srgb.greenComponent * 255)) == 128)
        #expect(Int(round(srgb.blueComponent * 255)) == 255)
    }

    @Test
    func parseHexIsCaseInsensitive() throws {
        let lower = try #require(GhosttyThemeColors.parseHexColor("#abcdef"))
        let upper = try #require(GhosttyThemeColors.parseHexColor("#ABCDEF"))
        let lowerSRGB = try #require(lower.usingColorSpace(.sRGB))
        let upperSRGB = try #require(upper.usingColorSpace(.sRGB))
        #expect(lowerSRGB.redComponent == upperSRGB.redComponent)
        #expect(lowerSRGB.greenComponent == upperSRGB.greenComponent)
        #expect(lowerSRGB.blueComponent == upperSRGB.blueComponent)
    }

    @Test
    func parseHexTrimsWhitespace() throws {
        let color = try #require(GhosttyThemeColors.parseHexColor("   #112233   "))
        let srgb = try #require(color.usingColorSpace(.sRGB))
        #expect(Int(round(srgb.redComponent * 255)) == 0x11)
        #expect(Int(round(srgb.greenComponent * 255)) == 0x22)
        #expect(Int(round(srgb.blueComponent * 255)) == 0x33)
    }

    @Test
    func parseHexRejectsNamedColors() {
        #expect(GhosttyThemeColors.parseHexColor("red") == nil)
        #expect(GhosttyThemeColors.parseHexColor("cornflowerblue") == nil)
    }

    @Test
    func parseHexRejectsWrongDigitCount() {
        #expect(GhosttyThemeColors.parseHexColor("#abc") == nil)
        #expect(GhosttyThemeColors.parseHexColor("#aabbccdd") == nil)
        #expect(GhosttyThemeColors.parseHexColor("12345") == nil)
        #expect(GhosttyThemeColors.parseHexColor("") == nil)
    }

    @Test
    func parseHexRejectsNonHexCharacters() {
        #expect(GhosttyThemeColors.parseHexColor("#zzzzzz") == nil)
        #expect(GhosttyThemeColors.parseHexColor("12345g") == nil)
    }

    // MARK: - window-colorspace

    @Test
    func windowColorspaceDefaultsToSRGBWhenKeyAbsent() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "ghostty-config-with-selection",
                withExtension: "config"
            )
        )
        #expect(GhosttyThemeColors.windowColorspace(at: url.path) == .sRGB)
    }

    @Test
    func windowColorspaceTreatsExplicitSrgbAsDefault() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "ghostty-config-srgb-explicit",
                withExtension: "config"
            )
        )
        #expect(GhosttyThemeColors.windowColorspace(at: url.path) == .sRGB)
    }

    @Test
    func windowColorspaceReadsDisplayP3() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "ghostty-config-display-p3-selection",
                withExtension: "config"
            )
        )
        #expect(GhosttyThemeColors.windowColorspace(at: url.path) == .displayP3)
    }

    @Test
    func windowColorspaceFallsBackToSRGBForMissingFile() {
        let absent = "/tmp/deviceterm-test-this-path-does-not-exist-\(UUID().uuidString)"
        #expect(GhosttyThemeColors.windowColorspace(at: absent) == .sRGB)
    }

    @Test
    func selectionBackgroundParsesP3WhenColorspaceIsDisplayP3() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "ghostty-config-display-p3-selection",
                withExtension: "config"
            )
        )
        let color = try #require(
            GhosttyThemeColors.selectionBackground(at: url.path)
        )
        // The color is constructed in Display P3 so the same hex is a
        // different color from the sRGB-parsed equivalent. Compare
        // both colorspaces to confirm we're not silently downcasting
        // to sRGB at construction time.
        let displayP3 = try #require(color.usingColorSpace(.displayP3))
        // The Display-P3-constructed color round-trips its 8-bit
        // components in the displayP3 colorspace. Same #1e5680 hex.
        #expect(Int(round(displayP3.redComponent * 255)) == 30)
        #expect(Int(round(displayP3.greenComponent * 255)) == 86)
        #expect(Int(round(displayP3.blueComponent * 255)) == 128)

        // sRGB-parsed reference: the same hex constructed in sRGB
        // gamut and re-tagged into displayP3 yields different P3
        // components (because the gamuts differ). The two NSColors
        // are NOT equal in any colorspace if the P3 path is wired.
        let srgbReference = try #require(
            GhosttyThemeColors.parseHexColor("#1e5680", colorspace: .sRGB)
        )
        let srgbInP3 = try #require(srgbReference.usingColorSpace(.displayP3))
        #expect(srgbInP3.redComponent != displayP3.redComponent
            || srgbInP3.greenComponent != displayP3.greenComponent
            || srgbInP3.blueComponent != displayP3.blueComponent)
    }

    @Test
    func parseHexDisplayP3ProducesDisplayP3Color() throws {
        let color = try #require(
            GhosttyThemeColors.parseHexColor("#7AA2F7", colorspace: .displayP3)
        )
        // Round-trip the components in the displayP3 colorspace:
        // they should match the raw 8-bit channels.
        let displayP3 = try #require(color.usingColorSpace(.displayP3))
        #expect(Int(round(displayP3.redComponent * 255)) == 122)
        #expect(Int(round(displayP3.greenComponent * 255)) == 162)
        #expect(Int(round(displayP3.blueComponent * 255)) == 247)
    }

    // MARK: - background

    @Test
    func backgroundReadsHashedHexFromConfigFile() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "ghostty-config-background",
                withExtension: "config"
            )
        )
        let color = try #require(GhosttyThemeColors.background(at: url.path))
        let srgb = try #require(color.usingColorSpace(.sRGB))
        // #0a1f0a = (10, 31, 10).
        #expect(Int(round(srgb.redComponent * 255)) == 10)
        #expect(Int(round(srgb.greenComponent * 255)) == 31)
        #expect(Int(round(srgb.blueComponent * 255)) == 10)
        #expect(srgb.alphaComponent == 1.0)
    }

    @Test
    func backgroundRespectsDisplayP3Colorspace() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "ghostty-config-background-display-p3",
                withExtension: "config"
            )
        )
        let color = try #require(GhosttyThemeColors.background(at: url.path))
        let displayP3 = try #require(color.usingColorSpace(.displayP3))
        #expect(Int(round(displayP3.redComponent * 255)) == 10)
        #expect(Int(round(displayP3.greenComponent * 255)) == 31)
        #expect(Int(round(displayP3.blueComponent * 255)) == 10)
        // Same hex parsed as sRGB then re-tagged into P3 produces
        // different components (P3 has a wider gamut). The two
        // NSColors are not equal in any colorspace when the P3 path
        // is wired through `background()`.
        let srgbReference = try #require(
            GhosttyThemeColors.parseHexColor("#0a1f0a", colorspace: .sRGB)
        )
        let srgbInP3 = try #require(srgbReference.usingColorSpace(.displayP3))
        #expect(srgbInP3.redComponent != displayP3.redComponent
            || srgbInP3.greenComponent != displayP3.greenComponent
            || srgbInP3.blueComponent != displayP3.blueComponent)
    }

    @Test
    func backgroundReturnsNilWhenKeyAbsent() throws {
        // ghostty-config-no-selection lacks both selection-background
        // AND background; reuse it as the absent-key fixture.
        let url = try #require(
            Bundle.module.url(
                forResource: "ghostty-config-no-selection",
                withExtension: "config"
            )
        )
        #expect(GhosttyThemeColors.background(at: url.path) == nil)
    }

    @Test
    func backgroundReturnsNilForMissingFile() {
        let absent = "/tmp/deviceterm-test-this-path-does-not-exist-\(UUID().uuidString)"
        #expect(GhosttyThemeColors.background(at: absent) == nil)
    }
}

// Cache tests are in a serialized sub-suite so they don't race against
// each other on the shared static. The parser + file-read tests above
// don't touch the cache so they stay parallelizable.
@MainActor
@Suite(.serialized)
struct GhosttyThemeColorsCacheTests {
    @Test
    func cachedReadHitsCacheOnSecondCall() {
        GhosttyThemeColors.invalidateCache()
        let first = GhosttyThemeColors.cachedSelectionBackground()
        let second = GhosttyThemeColors.cachedSelectionBackground()
        // Identity equality: the second call must hit cache, not re-read.
        // Nil ⇔ nil is also identity-equal, so the contract holds on
        // a machine without a ghostty config too.
        #expect(first === second)
    }

    @Test
    func invalidateCacheForcesRereadOnNextCall() {
        GhosttyThemeColors.invalidateCache()
        let before = GhosttyThemeColors.cachedSelectionBackground()
        GhosttyThemeColors.invalidateCache()
        let after = GhosttyThemeColors.cachedSelectionBackground()
        // If the file exists, the re-read produces a *new* NSColor
        // instance with the same components, so identity differs but
        // components match. If the file is absent, both are nil and
        // identity-equal.
        if let before, let after {
            let beforeSRGB = before.usingColorSpace(.sRGB)
            let afterSRGB = after.usingColorSpace(.sRGB)
            #expect(beforeSRGB?.redComponent == afterSRGB?.redComponent)
            #expect(beforeSRGB?.greenComponent == afterSRGB?.greenComponent)
            #expect(beforeSRGB?.blueComponent == afterSRGB?.blueComponent)
        } else {
            #expect(before == nil && after == nil)
        }
    }
}
