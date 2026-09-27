// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

/// The Auto Layout priorities the tab strip's pills lay out under.
///
/// The strip is the window's `contentViewController` root view, so a horizontal
/// floor inside a pill is also a floor on the window. AppKit runs a window-edge
/// drag at `.dragThatCanResizeWindow`, and a constraint above that beats the
/// drag: the window stops narrowing instead of the pill compressing. Every
/// priority here is therefore strictly below it, and none is
/// `.windowSizeStayPut`, which is the window's own preference to hold its size
/// and not a value content should sit on.
///
/// They are listed in the order they yield, which is the order the pill sheds
/// what it is showing as the strip gets crowded.
@MainActor
enum TabPillLayout {
    /// The width a pill prefers before the strip starts compressing it.
    static let cellMinimumWidth: CGFloat = 180

    /// The narrowest width a pinned pill prefers: the terminal glyph, the
    /// widest of the single glyphs, plus the pill's insets. Every one-glyph
    /// pinned pill prefers the same width, and a pill drawing two glyphs
    /// prefers more. A preference, like `cellMinimumWidth`: it holds at
    /// `pinnedCellWidthPriority`, so a window drag can still narrow it.
    static let pinnedCellMinimumWidth: CGFloat = 39

    /// The width below which a pill drops its shortcut badge rather than
    /// rendering a clipped fragment of the chord.
    static let shortcutVisibilityWidth: CGFloat = 140

    /// The title yields first. It tail-truncates by design, so it is the one
    /// part of the pill that degrades into something still worth reading.
    static let titleCompression: NSLayoutConstraint.Priority = .defaultLow

    /// The badge yields next, because its chord stays discoverable in the
    /// Window menu.
    static let shortcutBadgeCompression = NSLayoutConstraint.Priority(rawValue: 470)

    /// Then the markers, which signal the tab's automation role and its
    /// protected state, neither of which the title carries.
    static let markerCompression = NSLayoutConstraint.Priority(rawValue: 480)

    /// The ✕ is the last thing in the pill to give, so a crowded strip stays
    /// clickable down to the window's minimum width.
    static let closeButtonCompression: NSLayoutConstraint.Priority = .dragThatCannotResizeWindow

    /// Holds `cellMinimumWidth`. Above every content priority, so a pill with
    /// room to grow takes it before its ✕ is squashed.
    static let cellMinimumWidthPriority = NSLayoutConstraint.Priority(rawValue: 495)

    /// Frees the pill's inner stack from the cell's trailing edge.
    ///
    /// `NSStackView` emits its edge insets and inter-view spacing at
    /// `.required`, so a required trailing pin floors every pill at a width no
    /// lower priority can relieve, and that floor multiplies by the tab count.
    /// Letting the pin break instead means a badly crowded pill overruns its
    /// own trailing edge by a few points, which beats jamming the window.
    static let stackTrailingPin = NSLayoutConstraint.Priority(rawValue: 495)

    /// Prefers the lone pill's full target width, yielding to a window resize
    /// and to higher-priority constraints.
    static let soloPillTarget = NSLayoutConstraint.Priority(rawValue: 495)

    /// Pins a cell to its sampled width for the length of a ✕-click run.
    ///
    /// Above `cellMinimumWidthPriority` so a rebuild mid-run cannot widen the
    /// pill back out from under the pointer, and below the drag threshold so
    /// narrowing the window ends the run's geometry rather than the window's
    /// resize.
    static let frozenWidthPin = NSLayoutConstraint.Priority(rawValue: 505)

    /// Holds a pinned pill at its preferred width. Above the stack's breakable
    /// trailing pin, so the pill keeps that width rather than stretching, and
    /// below the window-drag threshold like the rest of the band.
    static let pinnedCellWidthPriority = NSLayoutConstraint.Priority(rawValue: 505)
}
