// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A point-in-time census of the point-to-point tunnel links the OS is
/// currently maintaining to trusted devices.
///
/// While a trusted client holds the device's CoreDevice session, `remoted`
/// exposes its route through a `utun` addressed from a unique-local (`fd…`)
/// range, this host at `…::2` and the device at `…::1`. Capturing a snapshot is a
/// synchronous, unprivileged `getifaddrs` walk that keeps only those ULA
/// point-to-point links. Nothing here opens a socket or brings a tunnel up; it
/// only observes what is already there.
package struct ReachabilitySnapshot: Sendable, Equatable {
    /// One tunnel link: the carrying interface plus both ends of its ULA pair.
    package struct Link: Sendable, Equatable {
        package let interfaceName: String
        package let hostAddress: String
        package let deviceAddress: String

        package init(interfaceName: String, hostAddress: String, deviceAddress: String) {
            self.interfaceName = interfaceName
            self.hostAddress = hostAddress
            self.deviceAddress = deviceAddress
        }
    }

    package let links: [Link]

    package init(links: [Link]) {
        self.links = links
    }

    /// Enumerate the live ULA `utun` links at this moment.
    package static func capture() -> ReachabilitySnapshot {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return ReachabilitySnapshot(links: []) }
        defer { freeifaddrs(head) }

        var links: [Link] = []
        var cursor = head
        while let node = cursor {
            cursor = node.pointee.ifa_next
            if let link = tunnelLink(from: node.pointee) {
                links.append(link)
            }
        }
        return ReachabilitySnapshot(links: links)
    }

    /// Reduce one `ifaddrs` record to a `Link`, or nil when it is not a ULA
    /// `utun` point-to-point interface.
    private static func tunnelLink(from record: ifaddrs) -> Link? {
        let name = String(cString: record.ifa_name)
        guard name.hasPrefix("utun") else { return nil }
        guard let localAddr = record.ifa_addr,
            localAddr.pointee.sa_family == sa_family_t(AF_INET6),
            let host = presentation(of: localAddr),
            host.hasPrefix("fd")
        else { return nil }

        // The device is the far end of the point-to-point link. Trust the
        // kernel's stated peer (`ifa_dstaddr`) first; fall back to the
        // `…::2` → `…::1` addressing convention when it isn't populated.
        let device: String
        if let peerAddr = record.ifa_dstaddr,
            let peer = presentation(of: peerAddr),
            peer.hasPrefix("fd") {
            device = peer
        } else if host.hasSuffix("::2") {
            device = String(host.dropLast()) + "1"
        } else {
            return nil
        }

        return Link(interfaceName: name, hostAddress: host, deviceAddress: device)
    }

    /// The `inet_ntop` presentation string for an IPv6 `sockaddr`.
    private static func presentation(of address: UnsafeMutablePointer<sockaddr>) -> String? {
        var raw = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard let formatted = inet_ntop(AF_INET6, &raw, &buffer, socklen_t(INET6_ADDRSTRLEN)) else { return nil }
        return String(cString: formatted)
    }
}
