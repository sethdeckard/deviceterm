// SPDX-License-Identifier: GPL-3.0-or-later
//
// Client-facing wire shape for a daemon RPC result. Must stay
// byte-compatible with the matching daemon encoder (noted per type).

/// `daemon.ping` → `{version, pid}`. Mirrors `DaemonMethods.PingResponse`.
public struct DaemonPingResponse: Codable, Sendable, Equatable {
    public let version: String
    public let pid: Int32

    public init(version: String, pid: Int32) {
        self.version = version
        self.pid = pid
    }
}
