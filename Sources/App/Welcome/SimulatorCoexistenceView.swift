// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The content of the Simulator.app coexistence welcome.
///
/// Shown on machines where Simulator.app is installed, which Xcode 26 and
/// earlier ship. `DeviceHubCoexistenceView` is the Device Hub counterpart.
/// A machine with both apps, and both welcomes still unseen, gets both a
/// launch apart.
///
/// The window chrome, the title block, and the button belong to
/// `WelcomeScaffold`; this view supplies the hero and the prose.
struct SimulatorCoexistenceView: View {
    /// Whether this is the first-run gate or an explicit reopen, from
    /// the Help menu or the advisory's Learn More… button.
    let presentation: WelcomePresentation

    let onDismiss: () -> Void

    var body: some View {
        WelcomeScaffold(
            title: WelcomeCatalog.simulatorCoexistenceTitle,
            presentation: presentation,
            onDismiss: onDismiss,
            hero: { CoexistenceQuitIllustration(app: .simulator) },
            content: { explanation },
            footnote: { EmptyView() }
        )
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 14) {
            WelcomeSection(
                icon: "checkmark.circle.fill",
                tint: .green,
                heading: "DeviceTerm boots Simulators headless.",
                detail: "With Simulator.app closed, a sim you boot from a DeviceTerm tab "
                    + "opens no window of its own."
            )
            WelcomeSection(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                heading: "If Simulator.app is already running, you get two windows.",
                detail: "It watches for Simulator boots and attaches its own window to any sim "
                    + "that starts, including sims DeviceTerm booted. Apple ships no "
                    + "setting to turn that off."
            )
            WelcomeSection(
                icon: "xmark.circle.fill",
                tint: .red,
                heading: "Closing Apple's window shuts the Simulator down.",
                detail: "By default, closing a device window or quitting Simulator.app shuts "
                    + "that sim down, even one DeviceTerm booted. Its DeviceTerm pane "
                    + "closes at the same time."
            )

            // The three above describe how things behave; this one asks
            // the reader to do something. The rule marks that turn so
            // the recommendation doesn't read as a fourth fact.
            Divider()
                .padding(.vertical, 2)

            WelcomeSection(
                icon: "checkmark.circle.fill",
                tint: .green,
                heading: "For the best user experience, quit Simulator.app before booting a sim.",
                detail: "Closing a device window isn't enough: with others open the app keeps "
                    + "attaching, and closing the last one takes the sim down with it. "
                    + "Press ⌘Q while it's frontmost, or right-click its Dock icon and "
                    + "choose Quit."
            )
        }
    }
}
