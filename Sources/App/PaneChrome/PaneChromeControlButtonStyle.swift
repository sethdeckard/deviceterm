// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The press feedback for the pane chrome's symbol buttons: a rounded wash in
/// the theme tint while the button is held.
///
/// The buttons are bare SF Symbols, and `.borderless` only dims the glyph a
/// little on press, too faint to tell whether a click landed. Most of these
/// actions show nothing on the device straight away (Siri, Apple Pay, a
/// side-button press), so the button itself has to show it.
struct PaneChromeControlButtonStyle: ButtonStyle {
    /// Opacity of the wash while pressed. Low enough that the symbol stays
    /// legible on top of it.
    private static let pressedOpacity = 0.35
    /// Corner radius of the wash, small enough to read as a square button.
    private static let cornerRadius: CGFloat = 5

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(PaneChromeOverlay.themeTint)
                    .opacity(configuration.isPressed ? Self.pressedOpacity : 0)
            )
    }
}
