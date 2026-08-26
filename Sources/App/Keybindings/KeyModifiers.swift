// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// The four modifier keys a deviceterm shortcut may use.
///
/// Owned rather than storing `NSEvent.ModifierFlags` directly for two
/// reasons. It is unambiguously `Sendable` under Swift 6 strict
/// concurrency, so the whole chord value layer stays a plain value type.
/// And it models exactly the four modifiers we bind, so converting from
/// a live `NSEvent` silently drops the noise flags AppKit sets on real
/// events. `.function` and `.numericPad` ride along on every arrow key,
/// and `.capsLock` whenever it happens to be on. Comparing raw
/// `modifierFlags` would reject a genuine ⌥⌘→. Comparing `KeyModifiers`
/// cannot.
struct KeyModifiers: OptionSet, Hashable, Sendable {
    static let control = KeyModifiers(rawValue: 1 << 0)
    static let option = KeyModifiers(rawValue: 1 << 1)
    static let shift = KeyModifiers(rawValue: 1 << 2)
    static let command = KeyModifiers(rawValue: 1 << 3)

    let rawValue: Int

    var nsFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.control) { flags.insert(.control) }
        if contains(.option) { flags.insert(.option) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.command) { flags.insert(.command) }
        return flags
    }

    /// Apple's canonical glyph order, ⌃⌥⇧⌘, matching how these appear in
    /// a macOS menu so the pinned map reads the way the menu does.
    var displayString: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option) { out += "⌥" }
        if contains(.shift) { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Narrow a live event's flags to the four we model, discarding the
    /// noise AppKit attaches (`.function`, `.numericPad`, `.capsLock`).
    init(nsFlags: NSEvent.ModifierFlags) {
        var value: KeyModifiers = []
        if nsFlags.contains(.control) { value.insert(.control) }
        if nsFlags.contains(.option) { value.insert(.option) }
        if nsFlags.contains(.shift) { value.insert(.shift) }
        if nsFlags.contains(.command) { value.insert(.command) }
        self = value
    }
}
