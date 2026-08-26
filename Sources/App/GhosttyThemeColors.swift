// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DaemonProtocol
import Foundation
import SwiftUI

/// Pure helper for resolving ghostty's
/// `selection-background` color out of `~/.config/ghostty/config`.
/// Used by the drag drop-overlay and the focused-pane border so the
/// three visual cues (text-selection highlight inside a terminal, the
/// drag drop region, and the focused-pane ring) share a single source
/// color and read as one design system.
///
/// This is a one-shot read of the user's ghostty config at
/// first access and cached process-wide (`cachedSelectionBackground()`); it
/// honors only the direct `selection-background = <hex>` key and does
/// NOT follow `theme = name` indirection.
///
/// REFACTOR: if layered theme-file traversal is added, resolve theme
/// palettes here alongside the direct keys, and fire
/// `invalidateCache()` from the config-file watcher.
///
/// Color parsing accepts ghostty's hex forms only: `#RRGGBB` or bare
/// `RRGGBB`. Named CSS-ish colors (`red`, `cornflowerblue`, …) and
/// the `rgb()/hsl()` functional forms aren't recognized; the helper
/// returns nil for them and callers fall back to
/// `NSColor.controlAccentColor`. The fallback chain is intentional:
/// a fresh-install user without a ghostty config still gets a
/// sensible-looking drag overlay and focus border on the system
/// accent, and a power user who's themed their terminal gets the
/// matching color automatically.
///
/// **Colorspace**: ghostty honors a `window-colorspace = display-p3`
/// key that flips palette-hex interpretation from sRGB to Display P3,
/// matching the convention iTerm2 uses for its `.itermcolors` files
/// (every color is tagged P3). Without honoring it, deviceterm parses
/// the same `selection-background` hex as sRGB and macOS color-
/// manages sRGB→P3 at render time, washing the focus border + drag
/// overlay relative to the in-terminal text-selection color the
/// user actually sees. The reader picks up that key and constructs
/// the NSColor in the matching colorspace so all three cues line up.
@MainActor
enum GhosttyThemeColors {
    /// Which colorspace ghostty interprets palette hex values in. Set
    /// by ghostty's `window-colorspace` key (default `srgb`); the
    /// `display-p3` option matches iTerm2's `.itermcolors` convention
    /// where every color is tagged P3.
    enum WindowColorspace: Sendable, Equatable {
        case sRGB
        case displayP3
    }

    /// Default config path under the user's XDG config home.
    static let defaultConfigPath = XDGPaths.ghosttyConfig()

    // Cache storage for `cachedSelectionBackground()`. Process-wide and
    // MainActor-isolated so the read/write of these two is implicitly
    // serialized, so no NSLock is needed.
    private static var cachedColor: NSColor?
    private static var cacheReady = false

    // Parallel cache for `cachedBackground()`, the terminal pane's
    // background color, used to tint the chrome surfaces so the window
    // chrome inherits the user's terminal palette.
    private static var cachedBg: NSColor?
    private static var cachedBgReady = false

    /// One-shot read of `selection-background` from the ghostty config
    /// file at `configPath`. Returns nil when the file is absent, the
    /// key isn't present, or the value isn't a recognized hex color.
    /// Reuses `ConfigFile`'s parser substrate: ghostty's `key = value`
    /// format is the same shape deviceterm's config uses, so the loader
    /// reads it as-is. The hex is interpreted in whichever colorspace
    /// the same config file's `window-colorspace` key selects.
    static func selectionBackground(at configPath: String) -> NSColor? {
        let file = ConfigFile(path: configPath)
        guard let raw = file.value(forKey: "selection-background") else {
            return nil
        }
        let colorspace = parseWindowColorspace(file.value(forKey: "window-colorspace"))
        return parseHexColor(raw, colorspace: colorspace)
    }

    /// One-shot read of `background` from the ghostty config file at
    /// `configPath`. Returns nil when the file is absent, the key
    /// isn't present, or the value isn't a recognized hex color. Same
    /// shape as `selectionBackground(at:)`, and the hex is interpreted in
    /// whichever colorspace the same file's `window-colorspace` key
    /// selects.
    static func background(at configPath: String) -> NSColor? {
        let file = ConfigFile(path: configPath)
        guard let raw = file.value(forKey: "background") else {
            return nil
        }
        let colorspace = parseWindowColorspace(file.value(forKey: "window-colorspace"))
        return parseHexColor(raw, colorspace: colorspace)
    }

    /// Process-wide cached read of `background` from
    /// `defaultConfigPath`. Same caching contract as
    /// `cachedSelectionBackground()`: read once, reuse, clear via
    /// `invalidateCache()`. Chrome surfaces consume this to tint
    /// themselves with the terminal palette so a dark-green theme
    /// stains the chrome above the terminal subtly. Returns nil
    /// without reading when `GhosttyConfigOverride` ignores the
    /// user's config, so the chrome stays on system colors.
    static func cachedBackground() -> NSColor? {
        if GhosttyConfigOverride.ignoresUserConfig() { return nil }
        if cachedBgReady {
            return cachedBg
        }
        let resolved = background(at: defaultConfigPath)
        cachedBg = resolved
        cachedBgReady = true
        return resolved
    }

    /// SwiftUI-friendly accessor for the cached ghostty background
    /// color, applied at `opacity` (where the cached NSColor is fully
    /// opaque). Returns the system `windowBackgroundColor` when no
    /// ghostty `background` is set so a fresh-install user still
    /// gets a sensible chrome.
    static func backgroundSwiftUI(opacity: Double) -> SwiftUI.Color {
        if let resolved = cachedBackground() {
            return SwiftUI.Color(nsColor: resolved).opacity(opacity)
        }
        return SwiftUI.Color(nsColor: .windowBackgroundColor)
    }

    /// One-shot read of `window-colorspace` from the ghostty config
    /// file at `configPath`. Returns `.sRGB` when the key is absent
    /// or unrecognized, which is ghostty's documented default.
    ///
    /// Standalone probe used by the tests; production code reaches the
    /// colorspace through `selectionBackground(at:)`, which folds both
    /// reads into one `ConfigFile` instance. A future caller that
    /// wants both the color and the raw colorspace should refactor
    /// to share a single `ConfigFile` rather than calling both
    /// entry points, since this reader re-opens the file on every call.
    static func windowColorspace(at configPath: String) -> WindowColorspace {
        let file = ConfigFile(path: configPath)
        return parseWindowColorspace(file.value(forKey: "window-colorspace"))
    }

    /// Process-wide cached read of `selection-background` from
    /// `defaultConfigPath`. First call reads + parses; subsequent
    /// calls return the same value without touching disk. Both the
    /// drop overlay and the focused-pane border consume this, so the
    /// parse cost is paid once per process launch. Returns nil
    /// without reading when `GhosttyConfigOverride` ignores the
    /// user's config, so both cues fall back to the system accent.
    static func cachedSelectionBackground() -> NSColor? {
        if GhosttyConfigOverride.ignoresUserConfig() { return nil }
        if cacheReady {
            return cachedColor
        }
        let resolved = selectionBackground(at: defaultConfigPath)
        cachedColor = resolved
        cacheReady = true
        return resolved
    }

    /// Clear the cache so the next `cachedSelectionBackground()` or
    /// `cachedBackground()` call re-reads the file. Used by tests;
    /// future home for the prefs pane's config-file watcher hook.
    static func invalidateCache() {
        cachedColor = nil
        cacheReady = false
        cachedBg = nil
        cachedBgReady = false
    }

    /// Parse a ghostty-style hex color string. Accepts `#RRGGBB` or
    /// bare `RRGGBB`. Trimming, case-insensitive. Returns nil for any
    /// other shape (named colors, malformed hex, wrong digit count,
    /// non-hex characters). The `colorspace` argument selects whether
    /// the parsed components are interpreted as sRGB (ghostty's
    /// default) or Display P3 (when the user sets
    /// `window-colorspace = display-p3`). Internal so the tests can
    /// pin the parser's accepted shapes directly.
    static func parseHexColor(
        _ raw: String,
        colorspace: WindowColorspace = .sRGB
    ) -> NSColor? {
        var hex = raw.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") {
            hex = String(hex.dropFirst())
        }
        guard hex.count == 6,
            let value = UInt32(hex, radix: 16) else {
            return nil
        }
        let red = CGFloat((value >> 16) & 0xFF) / 255.0
        let green = CGFloat((value >> 8) & 0xFF) / 255.0
        let blue = CGFloat(value & 0xFF) / 255.0
        switch colorspace {
        case .sRGB:
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1.0)

        case .displayP3:
            return NSColor(displayP3Red: red, green: green, blue: blue, alpha: 1.0)
        }
    }

    /// Decode a `window-colorspace` raw value into the enum. ghostty
    /// accepts `srgb` (default) and `display-p3`; anything else is
    /// treated as the default rather than a hard error so a stray
    /// typo doesn't silently kill the color path.
    private static func parseWindowColorspace(_ raw: String?) -> WindowColorspace {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespaces) else {
            return .sRGB
        }
        switch trimmed.lowercased() {
        case "display-p3":
            return .displayP3

        default:
            return .sRGB
        }
    }
}
