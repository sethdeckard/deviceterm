// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Every welcome the app knows about, in the order they
/// would be shown.
///
/// Entries are kept in presentation order, and only the first unseen one
/// appears in any launch (`WelcomeSelection.next`), so putting a new
/// welcome first delays every unseen one behind it by a launch. Append
/// rather than prepend unless that is the intent.
///
/// Ids are written to the `welcome-seen` cache file, so renaming one
/// re-shows that welcome to everybody who already dismissed it and
/// hasn't set `welcome-messages = suppress`; `WelcomeCatalogTests` pins
/// them. Help menu items are not generated
/// from this list: each is wired by hand in `MainMenu.swift` against its
/// own `AppDelegate` action.
///
/// Both entries are coexistence explanations, and automatic presentation
/// gates each on its app being installed. Xcode 26 ships Simulator.app and
/// Xcode 27 ships Device Hub, so a machine can have one, both, or neither.
/// With one installed, the other app's welcome is never shown. With both
/// installed and both still unseen, the Simulator one comes first and
/// Device Hub follows on the next launch, because only one welcome appears
/// per launch. An id already in the seen cache is skipped, so a user who
/// dismissed the Simulator welcome before installing Xcode 27 meets Device
/// Hub first.
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

    /// Id of the Device Hub coexistence welcome, the Xcode 27 counterpart
    /// to `simulatorCoexistenceID`.
    static let deviceHubCoexistenceID = "device-hub-coexistence"

    /// **Device Hub**, two words, is the name the app shows in its own
    /// menu bar and the one Apple's documentation uses. `DeviceHub.app` is
    /// only the bundle on disk.
    static let deviceHubCoexistenceTitle = "Working with Apple's Device Hub"

    /// Presentation order: Simulator.app precedes Device Hub.
    static let messages: [WelcomeMessage] = [simulatorCoexistence, deviceHubCoexistence]

    private static let simulatorCoexistence = WelcomeMessage(
        id: simulatorCoexistenceID,
        title: simulatorCoexistenceTitle,
        isRelevant: { CoexistenceApp.simulator.isInstalled() },
        content: { presentation, dismiss in
            AnyView(
                SimulatorCoexistenceView(
                    presentation: presentation,
                    onDismiss: dismiss
                )
            )
        }
    )

    private static let deviceHubCoexistence = WelcomeMessage(
        id: deviceHubCoexistenceID,
        title: deviceHubCoexistenceTitle,
        isRelevant: { CoexistenceApp.deviceHub.isInstalled() },
        content: { presentation, dismiss in
            AnyView(
                DeviceHubCoexistenceView(
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
