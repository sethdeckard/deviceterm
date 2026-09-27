// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol

// How a hinge posture is named and drawn. An extension rather than members on
// the type, because `FoldPosture` lives in `DaemonProtocol`, which describes
// the wire and carries no presentation. Defined once here so the three
// surfaces that offer the postures, the ribbon's fold bar, the Device
// menu and the pane's context menu, cannot drift on a name or a glyph.
extension FoldPosture {
    /// Menu-cased label, as the user reads it.
    var chromeTitle: String {
        switch self {
        case .closed:
            return "Fold Closed"

        case .book:
            return "Fold to Book"

        case .open:
            return "Unfold"
        }
    }

    /// SF Symbol for this posture.
    ///
    /// The shut and bent postures take book glyphs, after the shape of the
    /// hinge and the name of the middle posture; the flat one takes a
    /// rectangle, which is what an unfolded device presents. SF Symbols
    /// carries no foldable-phone glyph on any macOS this app runs on:
    /// `iphone.fold` does not resolve, so the phone family cannot express the
    /// positions at all.
    var chromeSymbol: String {
        switch self {
        case .closed:
            return "book.closed"

        case .book:
            return "book"

        case .open:
            return "rectangle.portrait"
        }
    }
}
