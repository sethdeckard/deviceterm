// SPDX-License-Identifier: GPL-3.0-or-later
//
// VersionReport: `deviceterm version`.
//
// Reports the public CLI release version, the live daemon's wire
// version (probed via `daemon.ping`), the bundled CLI's expected RPC
// wire version, and the host's macOS version (a proxy for the
// CoreSimulator boundary, which doesn't expose its own version
// surface).
//
// Pure data type + formatter; the runner in main.swift fills in the
// fields (env reads, daemon ping) and prints either the human form
// or the JSON form via the global `--json` toggle.

import DaemonProtocol
import Foundation

public struct VersionReport: Encodable, Sendable, Equatable {
    /// `deviceterm-cli`'s own semver. Pinned at the CLI module's
    /// build-time constant.
    public let deviceterm: String
    /// The live daemon's wire version (from `daemon.ping`).
    /// Nil when the daemon is unreachable; the human formatter
    /// renders nil as "(not reachable)" so out-of-tab invocations
    /// stay informative.
    public let daemon: String?
    /// This bundled CLI's expected RPC wire version
    /// (`DaemonProtocolInfo.wireVersion`). A live `daemon` value that
    /// differs from `rpcWire` is the canonical interrupted-update
    /// diagnostic. The public `deviceterm` release version is an
    /// independent SemVer value and need not equal either wire value.
    public let rpcWire: String
    /// macOS host version. Proxy for the CoreSimulator boundary
    /// (which doesn't expose a queryable version constant) and the
    /// kVK / private-API targets deviceterm depends on.
    public let macOS: String

    public init(
        deviceterm: String,
        daemon: String?,
        rpcWire: String,
        macOS: String
    ) {
        self.deviceterm = deviceterm
        self.daemon = daemon
        self.rpcWire = rpcWire
        self.macOS = macOS
    }
}

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
