// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A bounded, concurrent TCP connect sweep used to locate the device's dynamic
/// service-directory endpoint among the tunnel's ephemeral ports.
///
/// The OS tunnel serves the directory on a dynamic port in the ephemeral range,
/// so there is no fixed port to dial. This sweep finds which ports are open;
/// `ChannelBroker` then handshake-probes those to pick the one that is the
/// directory. A fixed-width task window keeps the fan-out bounded.
enum PortSweep {
    /// Return the open ports in `range` on `deviceAddress`, sorted ascending. A
    /// port is "open" if a short-timeout connect succeeds.
    static func openPorts(
        on deviceAddress: String,
        range: Range<Int> = 49_152..<65_536,
        window: Int = 64
    ) async -> [UInt16] {
        let candidates = Array(range)
        var open: [UInt16] = []
        var next = 0

        await withTaskGroup(of: UInt16?.self) { group in
            func probe(_ port: Int) {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    let channel = ByteChannel(host: deviceAddress, port: UInt16(port), readTimeout: 0.5)
                    defer { channel.close() }
                    return (try? await channel.connect(timeout: 0.2)) != nil ? UInt16(port) : nil
                }
            }

            // Stop scheduling new probes once the surrounding task is cancelled,
            // so a cancelled attach doesn't keep scanning thousands of ports.
            while next < candidates.count, next < window, !Task.isCancelled {
                probe(candidates[next])
                next += 1
            }
            while let result = await group.next() {
                if let port = result { open.append(port) }
                if next < candidates.count, !Task.isCancelled {
                    probe(candidates[next])
                    next += 1
                }
            }
        }
        return open.sorted()
    }
}
