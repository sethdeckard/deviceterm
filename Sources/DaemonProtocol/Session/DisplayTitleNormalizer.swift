// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The one routine that turns a raw OSC 0/2
/// terminal title into a value safe to store and republish.
///
/// A tab's display title is written by whatever program runs in that tab,
/// so it is fully caller-controlled text that ends up in a daemon-wide
/// read (`tabs.list`). Two properties matter:
///
///   - **Bounded.** Untreated, an OSC title is unbounded, so it would be
///     both an unbounded XPC payload and unbounded daemon state. The GUI
///     applies this before encoding the request (keeping the payload
///     small) and the daemon applies it again on receipt (keeping the
///     enforcement honest regardless of client).
///   - **Non-deceptive, in three specific senses.** Bidi controls can
///     visually reorder a label so one tab impersonates another's activity
///     string; C0/C1 controls can break a consumer's line-oriented output;
///     and an all-invisible title renders blank while still carrying a
///     non-nil value, blanking the label instead of letting the consumer
///     fall back to the session name. So the bidi controls and the
///     controls go, every other `Default_Ignorable_Code_Point` goes, and a
///     final check requires something in the result to actually render.
///     That last check is what covers the blank scalars no Unicode property
///     identifies (`U+2800`).
///
///     What this deliberately does NOT guarantee is that two distinct
///     titles always LOOK distinct. ZWNJ, ZWJ, and the variation selectors
///     survive inside a visible cluster (see `isProhibited`), because they
///     are orthographic in Persian and several Indic scripts and structural
///     inside emoji sequences, so `"a\u{200D}"` and `"a"` are different
///     values that render the same. Stripping them to close that gap would
///     corrupt legitimate titles, which is the worse trade for a label
///     whose whole job is to describe a tab to a human. Nothing resolves a
///     tab by its display title: `shortId` is the identifier, and
///     `tabs.list` documents `displayTitle` as explicitly not one.
///
/// Pipeline order matters: strip prohibited scalars, THEN
/// NFC-normalize (stripping first is what makes the surviving neighbours
/// compose against each other, and what makes the byte budget account for
/// the FINAL composed form rather than a longer decomposed one), THEN
/// accumulate whole `Character`s while the byte budget allows (so the cut
/// never splits a grapheme cluster into invalid UTF-8).
///
/// The result is Optional: `normalize` returns nil when filtering or
/// trimming leaves nothing, when no retained scalar renders, or when the
/// first grapheme already exceeds the byte budget. Nil rather than "":
/// consumers fall back to the session name, where an empty string would
/// blank the label instead.
public enum DisplayTitleNormalizer {
    /// UTF-8 byte ceiling for a stored/transmitted display title.
    /// Generous for a tab label, small enough that a hostile title is
    /// not a metadata channel of consequence.
    public static let byteBudget = 256

    /// Scalars examined before giving up. A work bound, not a policy: the
    /// caller runs this on the main actor for every title a program inside
    /// the tab emits, against text that program fully controls, so an
    /// unbounded megabyte title must not cost an O(n) strip + NFC pass
    /// each time.
    ///
    /// For a title of ordinary shape the bound is invisible, since every
    /// retained scalar costs at least one UTF-8 byte, so the byte budget
    /// runs out long before the scan does. It shows only on a title that
    /// spends the scan on scalars costing no bytes: a long prohibited
    /// prefix is dropped for free and can consume the limit, taking a
    /// visible suffix down with it. That is the deliberate trade against
    /// work, and such a title is not one worth preserving intact.
    private static let scalarScanLimit = 4 * byteBudget

    /// `U+2800` BRAILLE PATTERN BLANK: the braille block's *space*, a
    /// pattern with no raised dots. It renders as nothing, yet carries
    /// neither the whitespace nor the default-ignorable property (its
    /// category is `Symbol, other`), so both filters below miss it. It is
    /// the one blank-rendering scalar Unicode gives no property to catch.
    ///
    /// It is treated as whitespace rather than prohibited, because inside a
    /// genuine braille title it *is* the word separator: stripping it would
    /// run the words together. So it trims at the edges like a space and
    /// never counts as visible content, but survives between characters.
    private static let brailleBlank: Unicode.Scalar = "\u{2800}"

    private static let trimmable: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(brailleBlank)
        return set
    }()

    /// Normalize a raw title. Returns nil when nothing survives.
    public static func normalize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var kept = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars.prefix(scalarScanLimit) where !isProhibited(scalar) {
            kept.append(scalar)
        }
        let composed = String(kept).precomposedStringWithCanonicalMapping
        var bounded = ""
        var byteCount = 0
        // Grapheme-wise accumulation, not `utf8.prefix`: a multi-byte
        // emoji or a ZWJ sequence must be kept whole or dropped whole.
        for character in composed {
            let width = String(character).utf8.count
            if byteCount + width > byteBudget { break }
            bounded.append(character)
            byteCount += width
        }
        let trimmed = bounded.trimmingCharacters(in: trimmable)
        return hasVisibleContent(trimmed) ? trimmed : nil
    }

    /// Scalars removed outright: the controls, the line/paragraph
    /// separators, and every `Default_Ignorable_Code_Point`.
    ///
    /// The default-ignorable property is the right axis because it is
    /// exactly "renders as nothing": it covers the `Bidi_Control`
    /// overrides and isolates, the marks (`U+200E`/`U+200F`/`U+061C`), the
    /// invisible-math operators, the soft hyphen, ZWSP, the BOM, the
    /// Hangul filler, and the tag characters that make invisible text
    /// smuggling possible. An enumerated deny-list keeps missing members
    /// of that set (`U+2060` WORD JOINER was one), and every miss is a
    /// title that renders blank while still holding a non-nil value.
    ///
    /// Three exceptions stay, because they are ignorable but load-bearing
    /// *inside* a visible cluster: `U+200D` ZERO WIDTH JOINER (legitimate
    /// emoji sequences), `U+200C` ZERO WIDTH NON-JOINER (orthographic in
    /// Persian and several Indic scripts), and the variation selectors
    /// (emoji presentation, CJK ideographic variants). None of the three
    /// counts as visible content on its own; see `isInvisible`.
    private static func isProhibited(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F, 0x80...0x9F:
            return true                          // C0 controls, DEL, C1 controls

        case 0x2028, 0x2029:
            return true                          // line / paragraph separators

        case 0x200C, 0x200D:
            return false                         // ZWNJ, ZWJ

        case 0xFE00...0xFE0F, 0xE0100...0xE01EF:
            return false                         // variation selectors

        default:
            return scalar.properties.isDefaultIgnorableCodePoint
        }
    }

    /// Whether anything left in the normalized string actually renders.
    /// The kept joiners and variation selectors, and any combining marks
    /// with nothing to combine with, are invisible on their own, so a
    /// title made only of them must normalize to nil rather than to a
    /// blank-looking label.
    private static func hasVisibleContent(_ title: String) -> Bool {
        title.unicodeScalars.contains { !isInvisible($0) }
    }

    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isWhitespace || scalar == brailleBlank { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .nonspacingMark, .enclosingMark,
            .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return true

        default:
            return false
        }
    }
}
