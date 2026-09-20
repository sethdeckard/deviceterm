// SPDX-License-Identifier: GPL-3.0-or-later

@testable import App
import AppKit
import Testing

/// Pin `NSImage.menuSymbol`'s resolution order.
///
/// Verifies resolution order using a deliberately nonexistent name, so the
/// fallback is exercised independently of the host's symbol catalog. A test
/// naming a real newer symbol would skip the fallback path entirely on any
/// host new enough to vend it.
@MainActor
struct MenuSymbolTests {
    /// A deliberately nonexistent symbol name.
    private static let unavailable = "deviceterm.no.such.symbol"

    @Test
    func resolvesAnAvailableSymbol() {
        #expect(NSImage.menuSymbol("gear", describedAs: "Settings") != nil)
    }

    @Test
    func returnsNilForAnUnavailableSymbolWithNoFallback() {
        #expect(NSImage.menuSymbol(Self.unavailable, describedAs: "Missing") == nil)
    }

    @Test
    func fallsBackWhenThePreferredSymbolIsUnavailable() {
        let image = NSImage.menuSymbol(
            Self.unavailable,
            describedAs: "Siri",
            fallback: "waveform"
        )
        #expect(image != nil)
    }

    @Test
    func returnsNilWhenTheFallbackIsAlsoUnavailable() {
        let image = NSImage.menuSymbol(
            Self.unavailable,
            describedAs: "Missing",
            fallback: Self.unavailable
        )
        #expect(image == nil)
    }

    /// The fallback is a second choice, not an override: a caller whose
    /// preferred symbol is present must still get that one.
    ///
    /// The glyph sizes must differ so the final assertion can distinguish the
    /// preferred symbol from the fallback.
    @Test
    func prefersTheFirstSymbolWhenBothResolve() {
        let preferred = NSImage.menuSymbol("gear", describedAs: "Settings")
        let other = NSImage.menuSymbol("waveform", describedAs: "Siri")
        #expect(preferred?.size != other?.size, "sizes must differ to distinguish the two")
        let withFallback = NSImage.menuSymbol(
            "gear",
            describedAs: "Settings",
            fallback: "waveform"
        )
        #expect(withFallback?.size == preferred?.size)
    }

    /// Templates are what let a highlighted row tint the glyph with its text,
    /// and `withSymbolConfiguration` vends a fresh instance, so the flag has to
    /// survive onto the sized image the caller actually receives.
    @Test
    func vendsATemplateImageThroughBothPaths() {
        #expect(NSImage.menuSymbol("gear", describedAs: "Settings")?.isTemplate == true)
        let viaFallback = NSImage.menuSymbol(
            Self.unavailable,
            describedAs: "Siri",
            fallback: "waveform"
        )
        #expect(viaFallback?.isTemplate == true)
    }
}
