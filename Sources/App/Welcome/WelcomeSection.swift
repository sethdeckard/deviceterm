// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// One point in a welcome's explanation: a bold lead-in over `.secondary`
/// body text, behind a semantic icon.
///
/// Every point in a welcome uses this, so they read as one sequence rather
/// than as separate notes.
///
/// The icon exists because several equally-bold headings give a skimming
/// reader nothing to tell a problem from the advice. Shape carries that,
/// not just color: a check and a cross stay distinguishable without color
/// vision.
struct WelcomeSection: View {
    /// SF Symbol name. `checkmark.circle.fill` for behavior that works in
    /// the reader's favor or for the action to take,
    /// `exclamationmark.triangle.fill` and `xmark.circle.fill` for what
    /// will bite.
    let icon: String

    let tint: Color

    let heading: String

    /// Named `detail` rather than `body`, which `View` has already taken.
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(heading)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
