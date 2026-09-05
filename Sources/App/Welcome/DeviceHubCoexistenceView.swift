// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The content of the Device Hub coexistence welcome.
///
/// Shown on machines where Device Hub is installed, which Xcode 27 ships.
/// `SimulatorCoexistenceView` is the Simulator.app counterpart. A machine
/// with both apps, and both welcomes still unseen, gets both a launch
/// apart.
///
/// It reaches the same recommendation as the Simulator welcome, and for
/// the same reason: DeviceTerm doesn't need Apple's app running, so quit
/// it before booting a sim. What differs is the middle. Device Hub has no
/// duplicate-window problem to warn about, and brings two hazards of its
/// own instead: a quit that shuts down every booted Simulator, and
/// exclusive control of a physical device.
///
/// That it keeps everything in one window is why the duplicate-window
/// warning is absent, not a point the welcome makes. Saying so out loud
/// spends a section on a problem the reader doesn't have.
///
/// The ⌥ escape rides on the shutdown point rather than standing as
/// advice of its own. It answers the question that point raises, for a
/// reader who has sims booted right now, and it is not what to do in
/// general. Holding ⌥ overrides that one quit without changing the saved
/// default, and no UI for reaching that default was found, so quitting
/// Device Hub before booting stays the recommendation.
///
/// What it claims is bounded by `Tests/Manual/device-hub-coexistence.md`,
/// which records what was actually observed and what was not.
///
/// The window chrome, the title block, and the button belong to
/// `WelcomeScaffold`; this view supplies the hero and the prose.
struct DeviceHubCoexistenceView: View {
    /// Whether this is the first-run gate or an explicit Help-menu reopen.
    /// Help is the only way back to this topic; the Learn More… button
    /// that also reopens the Simulator welcome belongs to an advisory
    /// Device Hub doesn't have.
    let presentation: WelcomePresentation

    let onDismiss: () -> Void

    var body: some View {
        WelcomeScaffold(
            title: WelcomeCatalog.deviceHubCoexistenceTitle,
            presentation: presentation,
            onDismiss: onDismiss,
            hero: { CoexistenceQuitIllustration(app: .deviceHub) },
            content: { explanation },
            footnote: { crossReference }
        )
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 14) {
            WelcomeSection(
                icon: "checkmark.circle.fill",
                tint: .green,
                heading: "DeviceTerm boots Simulators headless.",
                detail: "It doesn't launch Device Hub. A sim you boot from a DeviceTerm tab "
                    + "runs in its pane."
            )
            WelcomeSection(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                heading: "On a physical device, only one app can drive it.",
                detail: "Device Hub and DeviceTerm can both show the same device's screen at "
                    + "once, and neither mirror drops. Control is what they can't share: "
                    + "interact from the other app and nothing happens for a while, then "
                    + "control moves there and the first app goes dead."
            )
            WelcomeSection(
                icon: "xmark.circle.fill",
                tint: .red,
                heading: "Quitting Device Hub shuts down every booted Simulator.",
                detail: "Not only the ones you opened in it. A sim DeviceTerm booted is shut "
                    + "down the same way, whether or not you ever selected it there, and "
                    + "its DeviceTerm pane closes with it. Holding ⌥ turns Quit into Quit "
                    + "and Keep Simulators Running (⌥⌘Q), but that's a one-time choice "
                    + "rather than a setting."
            )

            // The three above describe how things behave; this one asks
            // the reader to do something. The rule marks that turn so
            // the recommendation doesn't read as a fourth fact.
            Divider()
                .padding(.vertical, 2)

            WelcomeSection(
                icon: "checkmark.circle.fill",
                tint: .green,
                heading: "For the best user experience, quit Device Hub before booting a sim.",
                detail: "DeviceTerm doesn't need it running, and quitting it later takes "
                    + "your booted sims down with it. Press ⌘Q while it's frontmost, or "
                    + "right-click its Dock icon and choose Quit."
            )
        }
    }

    /// Points at the other coexistence welcome, and only when its app is
    /// on the machine. Both Xcodes installed is the case where a reader
    /// meets two apps that behave differently, and the seen-once rule
    /// means the Simulator welcome may have gone by a launch earlier.
    @ViewBuilder private var crossReference: some View {
        if CoexistenceApp.simulator.isInstalled() {
            Text(
                "You also have Simulator.app, from Xcode 26. It behaves differently. "
                    + "See Help ▸ \(WelcomeCatalog.simulatorCoexistenceTitle)."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
