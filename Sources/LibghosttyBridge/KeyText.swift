// SPDX-License-Identifier: GPL-3.0-or-later

/// Pure classification helpers for the bridge's text → libghostty
/// `key.text` path. Mirrors stock Ghostty.app's
/// `NSEvent.ghosttyCharacters` (NSEvent+Extension.swift) + the
/// codepoint check in its `keyAction` (SurfaceView_AppKit.swift). The
/// shape is split across two helpers because the two filters fire at
/// different points in the pipeline:
///
/// - `disposition(scalar:)`: runs when the keyDown accumulator is
///   empty and the bridge falls back to event.characters. Three
///   cases keyed off the leading scalar:
///   - `.drop`: Apple's Private Use Area function-key range
///     (0xF700–0xF8FF: arrows, F-keys, Home/End/PgUp/PgDn).
///     libghostty synthesizes the CSI escape from keycode + mods,
///     so sending the AppKit PUA codepoint on top double-emits.
///     Reproducer: Up arrow producing raw UTF-8 for U+F700
///     instead of `ESC [ A`.
///   - `.stripControl`: control byte (< 0x20). Caller re-fetches
///     `characters(byApplyingModifiers: flags - .control)` so the
///     text it passes onward is the unshifted letter ("c" for
///     Ctrl+C, "\t" for Shift+Tab since shift doesn't shift tab).
///     The control modifier remains in `mods` but is excluded
///     from `consumed_mods`, so libghostty's KeyEncoder re-applies
///     it on encode.
///   - `.forward`: printable ASCII + higher Unicode (CJK / emoji).
///     Pass `characters` as-is.
///
/// - `shouldForwardText(_:)`: the gate at the `sendKey` boundary.
///   Whatever path produced the text (accumulator or fallback),
///   drop it if its leading byte is still < 0x20. Stock Ghostty.app
///   does the same filter in `keyAction` and explicitly calls out
///   "without this, ctrl+enter does the wrong thing." It's also
///   what fixes Shift+Tab: AppKit accumulates "\t" for both Tab and
///   Shift+Tab, and forwarding the raw control byte alongside SHIFT
///   mods leaves libghostty's encoder no signal that it should
///   synthesize `CSI Z` (reverse tab). Passing nil lets the encoder
///   own control-byte synthesis from keycode + mods + unshifted_
///   codepoint, which is the canonical path.
///
/// Pure helpers (no AppKit dependency) so the classification matrix
/// is unit-testable per AGENTS.md's "pure math namespaces / decision
/// types" convention.
enum KeyText {
    /// Disposition of an `NSEvent.characters` leading scalar. See
    /// `KeyText` for the rules.
    enum Disposition: Equatable {
        case drop
        case stripControl
        case forward
    }

    /// Classify the leading scalar of `NSEvent.characters`.
    static func disposition(scalar value: UInt32) -> Disposition {
        if (0xF700...0xF8FF).contains(value) { return .drop }
        if value < 0x20 { return .stripControl }
        return .forward
    }

    /// Equivalent to `disposition(scalar:) == .forward`. Used only by
    /// the arrow-key regression tests, which assert the forward/drop
    /// rule directly rather than through the three-case disposition.
    static func forwardable(scalar value: UInt32) -> Bool {
        disposition(scalar: value) == .forward
    }

    /// The `sendKey`-boundary filter: pass `text` to libghostty only
    /// when its leading UTF-8 byte is >= 0x20. Empty, nil, or
    /// control-byte text yields nil, so libghostty synthesizes the
    /// terminal sequence from keycode / mods / unshifted_codepoint
    /// instead of double-encoding atop pre-cooked bytes. Matches the
    /// `keyAction` check in stock Ghostty.app's SurfaceView_AppKit.
    static func shouldForwardText(_ text: String?) -> Bool {
        guard let text, let leading = text.utf8.first else { return false }
        return leading >= 0x20
    }
}
