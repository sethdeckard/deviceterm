// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Renders a `SessionReport` for `deviceterm session show`.
public enum SessionReportFormat {
    /// Render as a human-readable column block, matching `deviceterm version`.
    /// Stable layout, so position is parseable too.
    ///
    /// A missing id has two causes and they are not the same answer. Without a
    /// role, the connection has no authenticated session, which covers a caller
    /// outside a tab and one inside a tab whose credentials are missing or
    /// empty. With a role, the session is real and the daemon just did not name
    /// it, which is what a daemon predating the field does.
    public static func formatHuman(_ report: SessionReport) -> String {
        let session = report.id
            ?? (report.role == nil ? "(no authenticated session)" : "(not reported)")
        let rows: [(String, String)] = [
            ("session", session),
            ("role", report.role?.rawValue ?? "(none)"),
            ("automation", report.automationGrant ? "granted" : "not granted")
        ]
        let labelWidth = 14
        return rows
            .map { label, value in
                label.padding(toLength: labelWidth, withPad: " ", startingAt: 0) + value
            }
            .joined(separator: "\n") + "\n"
    }
}
