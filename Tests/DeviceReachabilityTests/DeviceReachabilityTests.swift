// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import DeviceReachability

// DeviceReachability: the live tunnel census (`ReachabilitySnapshot`) and the
// bounded poll that pins a selected device to a `utun` (`DeviceRouteResolver`).
// The census test runs hermetically against whatever interfaces exist; the
// resolver tests drive both seams from fixtures so success and timeout paths
// run fast and without a real device.

private func link(_ name: String, host: String, device: String) -> ReachabilitySnapshot.Link {
    ReachabilitySnapshot.Link(interfaceName: name, hostAddress: host, deviceAddress: device)
}

private func census(_ links: [ReachabilitySnapshot.Link]) -> ReachabilitySnapshot {
    ReachabilitySnapshot(links: links)
}

@Test("the live tunnel census is a no-root, ULA-only lookup")
func captureYieldsOnlyULATunnels() {
    // Doesn't assert a device is present, just that enumeration is safe to call
    // with none and keeps only ULA point-to-point `utun` links.
    for entry in ReachabilitySnapshot.capture().links {
        #expect(entry.interfaceName.hasPrefix("utun"))
        #expect(entry.hostAddress.hasPrefix("fd"))
        #expect(entry.deviceAddress.hasPrefix("fd"))
    }
}

@Test("the resolver pins the utun whose far end matches the advertised address")
func resolvesByAdvertisedAddress() async throws {
    let target = link("utun9", host: "fd00::2", device: "fd00::1")
    let decoy = link("utun8", host: "fd11::2", device: "fd11::1")
    let resolver = DeviceRouteResolver(
        addressSource: { _ in "fd00::1" },
        interfaceSource: { census([decoy, target]) }
    )
    let route = try await resolver.resolve(deviceId: "U", attempts: 3, interval: .milliseconds(1))
    #expect(route.deviceId == "U")
    #expect(route.interfaceName == "utun9")
    #expect(route.hostAddress == "fd00::2")
    #expect(route.deviceAddress == "fd00::1")
}

@Test("the resolver times out when the tunnel never advertises an address")
func timesOutWhenTunnelNeverConnects() async {
    let resolver = DeviceRouteResolver(
        addressSource: { _ in nil },
        interfaceSource: { census([]) }
    )
    await #expect(throws: DeviceReachabilityError.tunnelUnavailable(deviceId: "U")) {
        _ = try await resolver.resolve(deviceId: "U", attempts: 2, interval: .milliseconds(1))
    }
}

@Test("the resolver keeps waiting when the address is advertised but no utun matches")
func timesOutWhenSnapshotIncomplete() async {
    // The address is known, but the census never shows a link with that far end.
    // The resolver must not settle on a non-matching interface; it waits out
    // the window and reports the tunnel unavailable.
    let resolver = DeviceRouteResolver(
        addressSource: { _ in "fd00::1" },
        interfaceSource: { census([link("utun8", host: "fd11::2", device: "fd11::1")]) }
    )
    await #expect(throws: DeviceReachabilityError.tunnelUnavailable(deviceId: "U")) {
        _ = try await resolver.resolve(deviceId: "U", attempts: 2, interval: .milliseconds(1))
    }
}
