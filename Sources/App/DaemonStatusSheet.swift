// SPDX-License-Identifier: GPL-3.0-or-later
//
// DaemonStatusSheet: minimal helper-disabled sheet.
//
// Shown when `SMAppService.agent.status` is anything other than
// `.enabled` after registration. macOS 26 surfaces the matching
// disabled state under System Settings → **Login Items &
// Extensions** (the older "Background Items" label is gone), and
// the sheet's CTA deep-links to that pane.
//
// Deliberately minimal. A polished onboarding pass (pre-explain
// copy, screenshot, retry button) is a separate follow-up. This
// stub exists so the GUI never silently fails when the helper is
// disabled.

import AppKit
import ServiceManagement
import SwiftUI

/// Lightweight wrapper for opening system URLs. Injected so the
/// sheet's snapshot test can assert which URL was opened without
/// actually launching System Settings.
protocol DaemonSheetOpener: Sendable {
    func open(_ url: URL)
}

struct DefaultDaemonSheetOpener: DaemonSheetOpener {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

struct DaemonStatusSheet: View {
    /// Deep-link URL into System Settings → Login Items &
    /// Extensions. Stable since macOS 13 (the "Extensions"
    /// rename in 26 didn't change the bundle identifier in the
    /// URL).
    static let loginItemsURL: URL = URL(
        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    ) ?? URL(fileURLWithPath: "/")

    /// Status the sheet was constructed for; drives copy
    /// variants (`requiresApproval` vs `notRegistered`).
    let status: SMAppService.Status

    /// Dismissal callback. The host window controller owns the
    /// modal lifecycle; the sheet just invokes the callback when
    /// the user resolves it.
    let onDismiss: () -> Void

    /// Injected URL opener. Production uses
    /// `DefaultDaemonSheetOpener`; tests inject a fake.
    let opener: DaemonSheetOpener

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(headline)
                .font(.headline)
            Text(messageBody(for: status))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Open Login Items & Extensions") {
                    opener.open(Self.loginItemsURL)
                }
                Button("Dismiss", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 460)
    }

    private var headline: String {
        switch status {
        case .enabled:
            return "deviceterm helper is enabled"

        case .requiresApproval:
            return "Approve deviceterm helper"

        case .notRegistered:
            return "deviceterm helper is disabled"

        case .notFound:
            return "deviceterm helper not installed"

        @unknown default:
            return "deviceterm helper status unknown"
        }
    }

    init(
        status: SMAppService.Status,
        onDismiss: @escaping () -> Void,
        opener: DaemonSheetOpener = DefaultDaemonSheetOpener()
    ) {
        self.status = status
        self.onDismiss = onDismiss
        self.opener = opener
    }

    private func messageBody(for status: SMAppService.Status) -> String {
        switch status {
        case .enabled:
            return "No action needed. The helper will launch on demand."

        case .requiresApproval:
            return "macOS is waiting for approval before launching the deviceterm "
                + "helper. Open Login Items & Extensions, find deviceterm under "
                + "the Background section, and turn it on."

        case .notRegistered:
            return "The deviceterm helper is registered but disabled. Open Login "
                + "Items & Extensions, find deviceterm under the Background "
                + "section, and turn it on."

        case .notFound:
            return "Could not find the deviceterm helper in this build. Reinstall "
                + "DeviceTerm and relaunch."

        @unknown default:
            return "Could not determine the deviceterm helper's status."
        }
    }
}
