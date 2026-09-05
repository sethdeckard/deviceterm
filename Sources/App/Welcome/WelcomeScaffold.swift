// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// The chrome every welcome window shares: hero band, title block,
/// scrolling prose, and one pinned button.
///
/// Shaped like Apple's own first-run screens. The window is chromeless, so
/// a welcome owns its entire surface and that button is the only obvious
/// way forward.
///
/// The hero is the caller's illustration rather than decoration. What a
/// welcome is really teaching is one action, so the picture of that action
/// gets the top of the window and the prose underneath explains why.
///
/// Body text is leading-aligned and fixed-width even though the title
/// block is centered: centered prose reads badly past a line or two, which
/// is why `DaemonStatusSheet` sets the pattern this follows.
///
/// No "Don't show again" checkbox. Once a welcome's id is recorded,
/// automatic selection skips it, so the box would have nothing to
/// suppress; `welcome-messages` covers the case where someone wants none
/// of them. That is the deliberate asymmetry with `HeadlessAdvisory`,
/// which can re-fire on later launches and does carry one.
struct WelcomeScaffold<Hero: View, Content: View, Footnote: View>: View {
    /// Shown under the eyebrow, and named in the reopen hint. Comes from
    /// `WelcomeCatalog`, which is also where the Help item's title comes
    /// from, so the two can't drift.
    let title: String

    /// Whether this is the first-run gate or an explicit reopen, from the
    /// Help menu or an advisory's Learn More… button. Changes the button's
    /// verb and whether the reopen hint shows.
    let presentation: WelcomePresentation

    let onDismiss: () -> Void

    @ViewBuilder let hero: Hero

    @ViewBuilder let content: Content

    /// Optional content under the reopen hint. Pass `EmptyView()` when
    /// there is nothing to add.
    @ViewBuilder let footnote: Footnote

    var body: some View {
        VStack(spacing: 0) {
            // The hero and the button are pinned; only the prose between
            // them scrolls, and only when it has to. `.basedOnSize`
            // suppresses the bounce when the content fits, so on a normal
            // display this behaves exactly like a fixed window. It earns
            // its keep on a short screen or at an enlarged text size,
            // where the button would otherwise sit off the bottom of a
            // window that blocks the app from opening.
            heroBand

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    titleBlock
                    content
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
                VStack(spacing: 4) {
                    reopenHint
                    footnote
                }
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
    private var heroBand: some View {
        hero
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
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
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
    @ViewBuilder private var reopenHint: some View {
        if presentation == .firstRun {
            Text("You can open this again from Help ▸ \(title).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
