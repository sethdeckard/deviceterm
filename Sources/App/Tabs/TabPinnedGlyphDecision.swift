// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

/// What a pinned tab's pill shows in place of its title, and what hovering
/// it says.
///
/// A pinned pill is too narrow for a title, so its markers are all it
/// draws. A plain unprotected tab has none, and gets the terminal glyph so
/// the pill is never empty.
enum TabPinnedGlyphDecision {
    /// The glyphs a pinned pill draws, in order: the tab's markers exactly
    /// as an unpinned pill orders them, or the terminal glyph alone when
    /// there are none.
    static func glyphs(
        role: SessionRole,
        isEffectivelyProtected: Bool
    ) -> [TabPillMarker] {
        let markers = TabMarkerDecision.markers(
            role: role,
            isEffectivelyProtected: isEffectivelyProtected
        )
        return markers.isEmpty ? [.terminal] : markers
    }

    /// The pill's hover text: the title it no longer shows, then one line
    /// for each glyph that explains itself.
    static func toolTip(title: String, glyphs: [TabPillMarker]) -> String {
        ([title] + glyphs.compactMap(\.hoverText)).joined(separator: "\n")
    }
}
