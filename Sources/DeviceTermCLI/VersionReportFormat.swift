// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import Foundation

/// Renders a `VersionReport` for `deviceterm version`.
///
/// The runner in main.swift fills in the fields (env reads, daemon ping) and
/// prints either the human form here or the JSON form via the global `--json`
/// toggle.
public enum VersionReportFormat {
    /// The CLI's public release version. The internal RPC wire version is
    /// reported separately because it can change independently.
    public static let deviceTermCLIVersion = DeviceTermVersion.current

    /// Render the report as a human-readable column block. Stable
    /// layout so a screen-reader / agent can parse position too.
    public static func formatHuman(_ report: VersionReport) -> String {
        let rows: [(String, String)] = [
            ("deviceterm", report.deviceterm),
            ("daemon wire", report.daemon ?? "(not reachable)"),
            ("RPC wire", report.rpcWire),
            ("macOS", report.macOS)
        ]
        let labelWidth = 14
        var lines: [String] = []
        for (label, value) in rows {
            let padded = label.padding(
                toLength: labelWidth,
                withPad: " ",
                startingAt: 0
            )
            lines.append("\(padded)\(value)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// macOS version as a plain dot-separated string (e.g. "26.0").
    /// Pulled from `ProcessInfo.processInfo.operatingSystemVersion`.
    public static func macOSVersionString() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
