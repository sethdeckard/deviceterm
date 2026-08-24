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
// Pure data type; `VersionReportFormat` renders it and the runner in
// main.swift fills in the fields (env reads, daemon ping).

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
