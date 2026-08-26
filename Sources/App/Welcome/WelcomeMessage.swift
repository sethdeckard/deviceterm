// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// One first-run explanation the app presents in its own
/// window.
///
/// A welcome teaches a DeviceTerm behavior that is hard to discover and
/// expensive to learn the hard way. It is deliberately *not* a hazard
/// warning: `HeadlessAdvisory` owns the just-in-time "this sim can be
/// shut down from outside" alert, and can re-fire on later launches until
/// the user opts out, while a welcome stops appearing automatically once
/// its id is recorded and then stays reachable from the Help menu.
///
/// The type exists so a second welcome is one value appended to
/// `WelcomeCatalog` rather than another hardcoded window: the id, the
/// title, and the content are all the presentation machinery needs. Its
/// Help menu item is wired separately in `MainMenu.swift`.
@MainActor
struct WelcomeMessage {
    /// Stable identifier, recorded as one line in the `welcome-seen`
    /// cache file. Renaming one re-shows that welcome to every existing
    /// user who hasn't set `welcome-messages = suppress`, so these are
    /// pinned by a test the same way the advisory's suppression key is.
    let id: String

    /// The welcome window's title.
    let title: String

    /// Builds the message's content, given how it is being presented
    /// and a dismiss action to wire to its own button. Dismissal is a
    /// closure because the window controller owns the window's
    /// lifetime, not the view.
    ///
    /// A message that reads the same either way can ignore the
    /// presentation: `{ _, dismiss in … }`.
    let content: (_ presentation: WelcomePresentation, _ dismiss: @escaping () -> Void) -> AnyView
}
