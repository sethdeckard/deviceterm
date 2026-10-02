// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Matches a directory listing to the service ports the device is serving now.
///
/// A device may serve its directory to only one peer per host at a time. When
/// macOS's own `remoted` already holds that session, the bootstrap handshake
/// displaces it; `remoted` reconnects within about a second and displaces
/// bootstrap in turn, and every port the listing named closes. The listing
/// still describes the layout, because the device allocates each peer's
/// service ports as one block in the same order. So this finds the mirror
/// service among the live ports by a read-only call only that service answers,
/// moves every listed role by the same offset, and confirms the anchor still
/// answers once `remoted` has had time to return.
///
/// A device that serves several peers keeps the listed ports open, and they are
/// used as listed. The known directory port is excluded from service
/// handshakes, because any session opened there displaces the other peer
/// again; the TCP sweep still checks it, which opens no session.
enum LivePortResolver {
    /// Resolve `listing` to live channels, or return it unchanged when no live
    /// block can be matched, so the failure surfaces where the channel is used.
    static func resolve(
        _ listing: ChannelBroker.Listing,
        deviceAddress: String,
        attempts: Int = 4,
        settle: Duration = .seconds(1),
        confirmAfter: Duration = .milliseconds(750)
    ) async throws -> DeviceChannels {
        let listed = listing.channels
        guard let listedMirror = listed.port(for: .mirror),
            let feature = ChannelRole.mirror.identifyingFeature else { return listed }

        for _ in 0..<max(1, attempts) {
            try await Task.sleep(for: settle)
            if await allAccept(listed.servicePorts, deviceAddress) {
                try await Task.sleep(for: confirmAfter)
                let stillOpen = await allAccept(listed.servicePorts, deviceAddress)
                try Task.checkCancellation()
                if stillOpen { return listed }
                continue
            }
            try Task.checkCancellation()

            let open = await PortSweep.openPorts(on: deviceAddress).filter { $0 != listing.directoryPort }
            try Task.checkCancellation()
            // Within each block, start where the listing's layout puts the
            // mirror; the largest block is the likeliest to be the services.
            let candidates = serviceBlocks(open).flatMap { block -> [UInt16] in
                let predicted = Int(block[0]) + Int(listedMirror) - Int(listing.lowestListedPort)
                return block.sorted { abs(Int($0) - predicted) < abs(Int($1) - predicted) }
            }

            let anchor = await firstAnswering(feature, among: candidates, deviceAddress)
            try Task.checkCancellation()
            guard let anchor, let live = listed.shifted(by: Int(anchor) - Int(listedMirror)),
                Set(live.servicePorts).isSubset(of: open) else { continue }

            try await Task.sleep(for: confirmAfter)
            let confirmed = await answers(feature, at: anchor, deviceAddress)
            try Task.checkCancellation()
            if confirmed { return live }
        }
        return listed
    }

    /// Candidate service blocks in an ascending port list, largest first.
    ///
    /// The device allocates a peer's service ports as one contiguous block, but
    /// a sweep connect that times out can punch a hole in it, so runs separated
    /// by up to `maxGap` missing ports merge into one block. Blocks smaller than
    /// `minimumSize` are dropped: the ports scattered outside the service block
    /// include directory endpoints, and opening a session on one displaces the
    /// host's other peer.
    static func serviceBlocks(_ ports: [UInt16], maxGap: Int = 2, minimumSize: Int = 8) -> [[UInt16]] {
        var blocks: [[UInt16]] = []
        var current: [UInt16] = []
        for port in ports {
            if let last = current.last, Int(port) - Int(last) <= maxGap + 1 {
                current.append(port)
            } else {
                if !current.isEmpty { blocks.append(current) }
                current = [port]
            }
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks.filter { $0.count >= minimumSize }.sorted { $0.count > $1.count }
    }

    /// Whether every port accepts a bare TCP connection. A connect opens no
    /// device session, so it disturbs no other peer.
    private static func allAccept(_ ports: [UInt16], _ deviceAddress: String) async -> Bool {
        for port in ports {
            guard !Task.isCancelled else { return false }
            let channel = ByteChannel(host: deviceAddress, port: port, readTimeout: 0.5)
            defer { channel.close() }
            guard (try? await channel.connect(timeout: 0.5)) != nil else { return false }
        }
        return true
    }

    /// The first of `ports`, in order, whose service returns output for
    /// `feature`.
    private static func firstAnswering(
        _ feature: String,
        among ports: [UInt16],
        _ deviceAddress: String
    ) async -> UInt16? {
        // The socket operations ignore cancellation, so check between ports
        // rather than walking the whole block for a cancelled attach.
        for port in ports where !Task.isCancelled {
            guard await answers(feature, at: port, deviceAddress) else { continue }
            return port
        }
        return nil
    }

    /// Whether the service at `port` returns output for `feature`. Services
    /// that don't implement it refuse or drop the call.
    private static func answers(_ feature: String, at port: UInt16, _ deviceAddress: String) async -> Bool {
        let channel = DeviceChannel(host: deviceAddress, port: port, readTimeout: 1)
        defer { channel.close() }
        do {
            try await channel.connect(timeout: 1)
            _ = try await channel.invoke(feature)
            return true
        } catch {
            return false
        }
    }
}
