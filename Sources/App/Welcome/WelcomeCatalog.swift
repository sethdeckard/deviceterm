// SPDX-License-Identifier: GPL-3.0-or-later
//
// WelcomeCatalog: every welcome the app knows about, in the order they
// would be shown.
//
// Entries are kept in presentation order, and only the first unseen one
// appears in any launch (`WelcomeSelection.next`), so putting a new
// welcome first delays every unseen one behind it by a launch. Append
// rather than prepend unless that is the intent.
//
// Ids are written to the `welcome-seen` cache file, so renaming one
// re-shows that welcome to everybody who already dismissed it and
// hasn't set `welcome-messages = suppress`; `WelcomeCatalogTests` pins
// them. Help menu items are not generated
// from this list: each is wired by hand in `MainMenu.swift` against its
// own `AppDelegate` action.

import SwiftUI

@MainActor
enum WelcomeCatalog {
    /// Id of the Simulator.app coexistence welcome. Referenced by the
    /// advisory's Learn More… button, so it is a named constant rather
    /// than a literal at two call sites.
    static let simulatorCoexistenceID = "simulator-coexistence"

    /// The one place this title is written. It appears as the window's
    /// title, as the heading inside the content, and as the Help menu
    /// item, and three literals would drift.
    static let simulatorCoexistenceTitle = "Working with Apple's Simulator.app"

    static let messages: [WelcomeMessage] = [simulatorCoexistence]

    private static let simulatorCoexistence = WelcomeMessage(
        id: simulatorCoexistenceID,
        title: simulatorCoexistenceTitle,
        content: { presentation, dismiss in
            AnyView(
                SimulatorCoexistenceView(
                    presentation: presentation,
                    onDismiss: dismiss
                )
            )
        }
    )

    /// The message for `id`, or nil when the catalog doesn't know it (a
    /// stale id left in the cache file after a rename).
    static func message(for id: String) -> WelcomeMessage? {
        messages.first { $0.id == id }
    }
}
