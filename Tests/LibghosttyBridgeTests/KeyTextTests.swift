// SPDX-License-Identifier: GPL-3.0-or-later

@testable import LibghosttyBridge
import Testing

// KeyText.forwardable decides whether an NSEvent.characters value
// should be sent to libghostty as `text` alongside the keycode. The
// rule has to filter out everything libghostty re-synthesizes from
// keycode + mods. Sending those twice (once as keycode, once as
// PUA text) ships garbage UTF-8 to the PTY instead of the expected
// escape sequences, which is what arrow keys, F-keys, and
// Home/End/PgUp/PgDn all do without this filter.

@Test
func controlBytesAreNotForwarded() {
    #expect(KeyText.forwardable(scalar: 0x00) == false) // NUL
    #expect(KeyText.forwardable(scalar: 0x03) == false) // Ctrl-C
    #expect(KeyText.forwardable(scalar: 0x08) == false) // backspace
    #expect(KeyText.forwardable(scalar: 0x09) == false) // tab
    #expect(KeyText.forwardable(scalar: 0x0D) == false) // CR (Enter)
    #expect(KeyText.forwardable(scalar: 0x1B) == false) // Esc
    #expect(KeyText.forwardable(scalar: 0x1F) == false) // last control byte
}

@Test
func applePrivateUseAreaFunctionKeysAreNotForwarded() {
    // Arrow keys: the headline case for this filter.
    #expect(KeyText.forwardable(scalar: 0xF700) == false) // NSUpArrowFunctionKey
    #expect(KeyText.forwardable(scalar: 0xF701) == false) // NSDownArrowFunctionKey
    #expect(KeyText.forwardable(scalar: 0xF702) == false) // NSLeftArrowFunctionKey
    #expect(KeyText.forwardable(scalar: 0xF703) == false) // NSRightArrowFunctionKey
    // F-keys.
    #expect(KeyText.forwardable(scalar: 0xF704) == false) // F1
    #expect(KeyText.forwardable(scalar: 0xF70F) == false) // F12
    #expect(KeyText.forwardable(scalar: 0xF726) == false) // F35
    // Editing keys.
    #expect(KeyText.forwardable(scalar: 0xF727) == false) // Insert
    #expect(KeyText.forwardable(scalar: 0xF728) == false) // Delete (forward)
    #expect(KeyText.forwardable(scalar: 0xF729) == false) // Home
    #expect(KeyText.forwardable(scalar: 0xF72B) == false) // End
    #expect(KeyText.forwardable(scalar: 0xF72C) == false) // PageUp
    #expect(KeyText.forwardable(scalar: 0xF72D) == false) // PageDown
    // End of the PUA function-key block.
    #expect(KeyText.forwardable(scalar: 0xF8FF) == false)
}

@Test
func printableASCIIIsForwarded() {
    #expect(KeyText.forwardable(scalar: 0x20) == true) // space (lower bound)
    #expect(KeyText.forwardable(scalar: 0x31) == true) // '1' (Claude Code numbered-prompt key)
    #expect(KeyText.forwardable(scalar: 0x41) == true) // 'A'
    #expect(KeyText.forwardable(scalar: 0x61) == true) // 'a'
    #expect(KeyText.forwardable(scalar: 0x7E) == true) // '~' (last printable ASCII)
}

@Test
func higherUnicodeIsForwarded() {
    // Real-world non-ASCII input must not get accidentally filtered.
    #expect(KeyText.forwardable(scalar: 0x00A0) == true)  // NBSP
    #expect(KeyText.forwardable(scalar: 0x05D0) == true)  // Hebrew Aleph
    #expect(KeyText.forwardable(scalar: 0x4E2D) == true)  // CJK 中
    #expect(KeyText.forwardable(scalar: 0x1F389) == true) // 🎉
}

@Test
func pUABoundaryConditionsAreCorrect() {
    // Just below the function-key block, so it must forward.
    #expect(KeyText.forwardable(scalar: 0xF6FF) == true)
    // Just above the function-key block, so it must forward.
    #expect(KeyText.forwardable(scalar: 0xF900) == true)
}

// MARK: - disposition (Ctrl-letter / PUA / printable triage)

@Test
func controlBytesClassifyAsStripControl() {
    // Returning `.drop` (the earlier behavior) for control bytes
    // left libghostty without the text path that Ctrl-letter
    // encoding needs in raw-mode TUIs, so Claude Code / vim insert
    // mode / less / htop silently dropped Ctrl-letter keystrokes.
    // The right disposition is `.stripControl`: the caller passes
    // `event.characters(byApplyingModifiers: flags - .control)`
    // (i.e. the unshifted letter) and marks ctrl as not-consumed,
    // so libghostty's KeyEncoder re-applies ctrl and produces the
    // correct byte. Pinned for every control codepoint we expect
    // in the keystream.
    #expect(KeyText.disposition(scalar: 0x00) == .stripControl) // NUL
    #expect(KeyText.disposition(scalar: 0x03) == .stripControl) // Ctrl-C
    #expect(KeyText.disposition(scalar: 0x04) == .stripControl) // Ctrl-D (EOF)
    #expect(KeyText.disposition(scalar: 0x08) == .stripControl) // backspace
    #expect(KeyText.disposition(scalar: 0x09) == .stripControl) // Tab
    #expect(KeyText.disposition(scalar: 0x0D) == .stripControl) // CR (Enter)
    #expect(KeyText.disposition(scalar: 0x1A) == .stripControl) // Ctrl-Z
    #expect(KeyText.disposition(scalar: 0x1B) == .stripControl) // Esc
    #expect(KeyText.disposition(scalar: 0x1F) == .stripControl) // last control byte
}

@Test
func puaFunctionKeysClassifyAsDrop() {
    // Same set as the `forwardable` arrow-key test above. Keep
    // them as `.drop` so libghostty synthesizes the CSI escapes
    // from keycode + mods without a competing PUA text payload.
    #expect(KeyText.disposition(scalar: 0xF700) == .drop) // Up
    #expect(KeyText.disposition(scalar: 0xF702) == .drop) // Left
    #expect(KeyText.disposition(scalar: 0xF704) == .drop) // F1
    #expect(KeyText.disposition(scalar: 0xF729) == .drop) // Home
    #expect(KeyText.disposition(scalar: 0xF8FF) == .drop) // end of PUA
}

@Test
func printableScalarsClassifyAsForward() {
    #expect(KeyText.disposition(scalar: 0x20) == .forward)   // space
    #expect(KeyText.disposition(scalar: 0x61) == .forward)   // 'a'
    #expect(KeyText.disposition(scalar: 0x4E2D) == .forward) // CJK 中
    #expect(KeyText.disposition(scalar: 0x1F389) == .forward) // 🎉
}

// MARK: - shouldForwardText (the sendKey-boundary filter)

@Test
func shouldForwardTextDropsNilAndEmpty() {
    // The filter must say "no text" for missing or empty payloads so
    // libghostty receives nil and synthesizes from keycode + mods.
    #expect(KeyText.shouldForwardText(nil) == false)
    #expect(KeyText.shouldForwardText("") == false)
}

@Test
func shouldForwardTextDropsControlBytes() {
    // The Shift+Tab + Ctrl+Enter + raw-mode Ctrl-letter fix. Any
    // text whose leading byte is < 0x20 must be filtered out at the
    // sendKey boundary so libghostty owns control-byte synthesis
    // from keycode + mods + unshifted_codepoint.
    #expect(KeyText.shouldForwardText("\t") == false)     // Tab / Shift+Tab
    #expect(KeyText.shouldForwardText("\r") == false)     // Enter / Ctrl+Enter
    #expect(KeyText.shouldForwardText("\n") == false)     // LF
    #expect(KeyText.shouldForwardText("\u{08}") == false) // Backspace
    #expect(KeyText.shouldForwardText("\u{1B}") == false) // Esc
    #expect(KeyText.shouldForwardText("\u{03}") == false) // raw Ctrl-C
    #expect(KeyText.shouldForwardText("\u{1A}") == false) // raw Ctrl-Z
    #expect(KeyText.shouldForwardText("\u{1F}") == false) // last control byte
}

@Test
func shouldForwardTextPassesPrintable() {
    // Printable ASCII (space and up) + the Ctrl-letter unshifted
    // letter the bridge re-fetches via printableText for the
    // accumulator-empty path: filter must let these through.
    #expect(KeyText.shouldForwardText(" ") == true)   // space (lower bound)
    #expect(KeyText.shouldForwardText("a") == true)
    #expect(KeyText.shouldForwardText("c") == true)   // Ctrl+C unshifted
    #expect(KeyText.shouldForwardText("A") == true)
    #expect(KeyText.shouldForwardText("1") == true)
    #expect(KeyText.shouldForwardText("~") == true)
}

@Test
func shouldForwardTextPassesHigherUnicode() {
    // Multi-byte UTF-8: leading byte of CJK / emoji is well above
    // 0x20 (>= 0xC2 in UTF-8), so the byte-level check correctly
    // forwards them. CJK / Hebrew / emoji must reach libghostty.
    #expect(KeyText.shouldForwardText("中") == true)
    #expect(KeyText.shouldForwardText("é") == true)
    #expect(KeyText.shouldForwardText("🎉") == true)
}

@Test
func shouldForwardTextChecksOnlyLeadingByte() {
    // Defensive: a multi-character string starting with a control
    // byte is filtered (would only ever happen as a defensive
    // case, since accumulator items are single tokens). A multi-byte
    // string starting with a printable byte passes.
    #expect(KeyText.shouldForwardText("\u{1B}[A") == false) // ESC sequence
    #expect(KeyText.shouldForwardText("ab") == true)
}

@Test
func dispositionAndForwardableStayInSync() {
    // `forwardable` is the back-compat predicate (`disposition ==
    // .forward`); pin the equivalence so a future change to one
    // doesn't silently desync the other.
    for scalar: UInt32 in [
        0x00,
        0x03,
        0x1F,
        // stripControl
        0xF700,
        0xF8FF,
        // drop
        0x20,
        0x7E,
        0x4E2D,
        0x1F389            // forward
    ] {
        let forwardable = KeyText.forwardable(scalar: scalar)
        let disposition = KeyText.disposition(scalar: scalar)
        #expect(
            forwardable == (disposition == .forward),
            Comment(
                rawValue: "scalar 0x\(String(scalar, radix: 16)) "
                + "forwardable=\(forwardable) "
                + "disposition=\(disposition)"
                )
        )
    }
}
