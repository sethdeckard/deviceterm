// SPDX-License-Identifier: GPL-3.0-or-later

/// `daemon.ping` → `{version, pid}`. Mirrors `DaemonMethods.PingResponse`.
///
/// A client-facing wire shape for a daemon RPC result, so its fields and
/// wire keys must stay compatible with `DaemonMethods.PingResponse`.
public struct DaemonPingResponse: Codable, Sendable, Equatable {
    public let version: String
    public let pid: Int32

    public init(version: String, pid: Int32) {
        self.version = version
        self.pid = pid
    }
}
