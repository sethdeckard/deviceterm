// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// The SwiftUI content for the About window, showing app icon, name,
/// tagline, Version/Build/Commit rows, Docs + GitHub buttons, and the GPL
/// legal notice. Replaces the stock `orderFrontStandardAboutPanel`. Static
/// content (`AboutInfo`), so there is no view model; the value is
/// resolved when the window is created.
struct AboutView: View {
    let info: AboutInfo

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)

            VStack(spacing: 6) {
                Text(info.name)
                    .font(.system(size: 22, weight: .semibold))
                Text(info.tagline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                metadataRow("Version") { Text(info.version).monospacedDigit() }
                metadataRow("Build") { Text(info.build).monospacedDigit() }
                if let commit = info.commit {
                    metadataRow("Commit") { commitValue(commit) }
                }
            }
            .font(.callout)

            HStack(spacing: 10) {
                Link("Docs", destination: AppLinks.docs)
                    .buttonStyle(.bordered)
                Link("GitHub", destination: AppLinks.gitHub)
                    .buttonStyle(.bordered)
            }

            legalNotice
        }
        .padding(28)
        .frame(width: 320)
    }

    /// The four things the GPL's "Appropriate Legal Notices" definition asks
    /// an interactive program to display: the copyright, that licensees may
    /// redistribute it under this license, that it carries no warranty, and
    /// how to view the license.
    ///
    /// The notices link is here for a second reason. LGPL-2.1 section 6 asks
    /// that a program displaying copyright notices while it runs also carry
    /// the copyright for any LGPL library it links, plus a pointer to that
    /// license. libghostty statically links GNU libintl, so this is the
    /// pointer; the copyright itself lives in `THIRD_PARTY_NOTICES.md`.
    private var legalNotice: some View {
        VStack(spacing: 3) {
            Text(info.copyright)
                .foregroundStyle(.secondary)
            Text("Free software you may redistribute under the GNU GPL v3 or later, with absolutely no warranty.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Link("Read the license", destination: AppLinks.license)
                Button("Third-Party Notices") {
                    NSApp.sendAction(
                        #selector(AppDelegate.openThirdPartyNotices(_:)),
                        to: nil,
                        from: nil
                    )
                }
                .buttonStyle(.link)
            }
        }
        .font(.caption)
    }

    private func metadataRow<Value: View>(
        _ label: String,
        @ViewBuilder value: () -> Value
    ) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            value()
        }
    }

    @ViewBuilder
    private func commitValue(_ hash: String) -> some View {
        if let url = AppLinks.commit(hash) {
            Link(hash, destination: url).monospaced()
        } else {
            Text(hash).monospaced()
        }
    }
}
