// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The request half of the daemon transport, abstracted so `DaemonClient`
/// can be unit-tested without a live XPC/UDS connection.
///
/// `DaemonClient` dispatches `request`, `subscribe`, and `subscribeRaw`
/// over a concrete `XPCDaemonConnection` / `UDSDaemonConnection` enum.
/// The two subscribe paths post-process differently per transport
/// (XPC correlates IOSurface side-band payloads; UDS can't), so the
/// enum stays. Only `request` is uniform across both transports, so this
/// protocol captures exactly that one call so a test can inject a
/// scripted transport and drive the reconnect re-authentication path
/// (`request`'s -32001 retry) without a socket. Production never
/// injects; the enum path is unchanged.
protocol DaemonRequestTransport: Sendable {
    func request(method: String, params: Data?) async throws -> Data
}
