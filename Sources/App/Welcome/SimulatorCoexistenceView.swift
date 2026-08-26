// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The content of the Simulator.app
/// coexistence welcome.
///
/// Shaped like Apple's own first-run screens: a full-bleed hero band, an
/// eyebrow and large title, the explanation, then one prominent button.
/// The window is chromeless, so this view owns the entire surface and
/// that button is the only obvious way forward.
///
/// The hero is the quit illustration rather than decoration. What the
/// screen is really teaching is one action, so the picture of that action
/// gets the top of the window and the prose underneath explains why.
///
/// Body text is leading-aligned and fixed-width even though the title
/// block is centered: centered prose reads badly past a line or two,
/// which is why `DaemonStatusSheet` sets the pattern this follows.
///
/// No "Don't show again" checkbox. Once its id is recorded, automatic
/// selection skips this welcome, so the box would have nothing to
/// suppress; `welcome-messages` covers the case where someone wants none
/// of them. That is the deliberate asymmetry with `HeadlessAdvisory`,
/// which can re-fire on later launches and does carry one.
struct SimulatorCoexistenceView: View {
    /// Whether this is the first-run gate or an explicit reopen, from
    /// the Help menu or the advisory's Learn More… button. Changes the
    /// button's verb and whether the footnote shows.
    let presentation: WelcomePresentation

    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // The hero and the button are pinned; only the prose between
            // them scrolls, and only when it has to. `.basedOnSize`
            // suppresses the bounce when the content fits, so on a normal
            // display this behaves exactly like a fixed window. It earns
            // its keep on a short screen or at an enlarged text size,
            // where the button would otherwise sit off the bottom of a
            // window that blocks the app from opening.
            hero

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    titleBlock
                    explanation
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 2)
            }
            .scrollBounceBehavior(.basedOnSize)

            // Pinned, so the way forward is visible at any window size.
            // No rule above it: the button reads as part of the same
            // surface, and a line there only earns its place in the rare
            // case where the content actually scrolls under it.
            VStack(spacing: 10) {
                continueButton
                footnote
            }
            .padding(.horizontal, 32)
            .padding(.top, 4)
            // Tighter than the top: the footnote is a trailing aside, so
            // it sits closer to the edge than the hero does.
            .padding(.bottom, 16)
        }
        .frame(width: 780)
        // The window is `.fullSizeContentView` with a transparent
        // titlebar, but SwiftUI still insets for it, which leaves a bare
        // strip above the hero. Ignoring the top inset lets the gradient
        // run to the window's own edge.
        .ignoresSafeArea(edges: .top)
    }

    /// Full-bleed band carrying the illustration. A soft accent wash
    /// rather than a flat fill so it reads as a hero rather than as
    /// another content box, and stays semantic in both appearances.
    private var hero: some View {
        SimulatorQuitIllustration()
            // Still more on top than bottom, to offset the titlebar
            // height the band extends through, so the illustration reads
            // as centered in the band rather than sitting low in it.
            .padding(.top, 40)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity)
            .background {
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.22),
                        Color.accentColor.opacity(0.06)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay(alignment: .bottom) {
                Divider()
            }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("DeviceTerm")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(WelcomeCatalog.simulatorCoexistenceTitle)
                .font(.system(size: 24, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 14) {
            section(
                icon: "checkmark.circle.fill",
                tint: .green,
                "DeviceTerm boots Simulators headless.",
                "With Simulator.app closed, a sim you boot from a DeviceTerm tab "
                    + "appears only in DeviceTerm."
            )
            section(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                "If Simulator.app is already running, you get two windows.",
                "It watches for Simulator boots and attaches its own window to any sim "
                    + "that starts, including sims DeviceTerm booted. Apple ships no "
                    + "setting to turn that off."
            )
            section(
                icon: "xmark.circle.fill",
                tint: .red,
                "Closing Apple's window shuts the Simulator down.",
                "By default, closing a device window or quitting Simulator.app shuts "
                    + "that sim down, even one DeviceTerm booted. Its DeviceTerm pane "
                    + "closes at the same time."
            )

            // The three above describe how things behave; this one asks
            // the reader to do something. The rule marks that turn so
            // the recommendation doesn't read as a fourth fact.
            Divider()
                .padding(.vertical, 2)

            section(
                icon: "checkmark.circle.fill",
                tint: .green,
                "For the best user experience, quit Simulator.app before booting a sim.",
                "Closing a device window isn't enough: with others open the app keeps "
                    + "attaching, and closing the last one takes the sim down with it. "
                    + "Press ⌘Q while it's frontmost, or right-click its Dock icon and "
                    + "choose Quit."
            )
        }
    }

    /// One prominent, centered action. The window has no visible close
    /// button, so this is the way forward and it should look like it.
    ///
    /// Sized explicitly rather than left to `.controlSize(.large)`,
    /// which renders a standard-height button that reads as incidental
    /// next to a hero band. The capsule shape and the width are what
    /// make it the obvious target.
    private var continueButton: some View {
        HStack {
            Spacer()
            Button(action: onDismiss) {
                // "Continue" on first run because the button genuinely
                // continues into the app: dismissing the welcome is what
                // opens the app's first window. On an explicit reopen
                // there is nothing to continue to, so it just closes.
                Text(presentation == .firstRun ? "Continue" : "Done")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 300, height: 34)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            Spacer()
        }
        .padding(.top, 6)
    }

    /// Where to find this again. The automatic presentation stops once
    /// the id is recorded, so someone who clicks through quickly has no
    /// way to know the screen is reopenable unless it says so before
    /// they dismiss it.
    ///
    /// Omitted on any explicit reopen. That covers Help, where naming
    /// the Help menu is noise, and also Learn More…, where it would not
    /// be; treating both the same avoids splitting `.reopened` into two
    /// cases for one line of text.
    @ViewBuilder private var footnote: some View {
        if presentation == .firstRun {
            Text("You can open this again from Help ▸ \(WelcomeCatalog.simulatorCoexistenceTitle).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    /// A bold lead-in over `.secondary` body text, behind a semantic
    /// icon. Every section uses it, so they read as one sequence rather
    /// than separate notes.
    ///
    /// The icon exists because four equally-bold headings give a skimming
    /// reader nothing to tell a problem from the advice. Shape carries
    /// that, not just color: a check and a cross stay distinguishable
    /// without color vision.
    private func section(
        icon: String,
        tint: Color,
        _ heading: String,
        _ body: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(heading)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
