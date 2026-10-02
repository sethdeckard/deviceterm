// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import ChannelBootstrap

/// Directory parsing → role discovery. The live socket path (sweep, concurrent
/// handshake probe, cancellation on first match) is exercised by the device
/// track; here the pure parse maps a directory reply to supported roles and
/// identity.
struct ChannelBrokerTests {
    private func directoryReply() -> DeviceObject {
        .object([
            ("Services", .object([
                // Port encoded as a string (as the device sends it)…
                ("com.apple.coredevice.hid.universalhidservice", .object([("Port", .text("51403"))])),
                // …and as an integer, to prove both coerce.
                ("com.apple.coredevice.displayservice", .object([("Port", .unsigned(51_404))])),
                ("com.apple.coredevice.hid.indigo", .object([("Port", .signed(51_405))]))
            ])),
            ("Properties", .object([
                ("UniqueDeviceID", .text("UDID-123")),
                ("ProductType", .text("iPhone17,1")),
                ("OSVersion", .text("27.0")),
                ("ProductTypeDescForUserVisibility", .text("iPhone 16 Pro"))
            ]))
        ])
    }

    @Test("a directory reply maps its services onto the supported roles")
    func rolesDiscovered() throws {
        let channels = try #require(parseDirectory())
        #expect(channels.supports(.humanInput))
        #expect(channels.supports(.mirror))
        #expect(channels.supports(.hardwareControls))
        // No devicecontrol service in the reply → the role is unsupported.
        #expect(!channels.supports(.deviceControl))
    }

    @Test("device identity is read from the directory properties")
    func identityParsed() throws {
        let channels = try #require(parseDirectory())
        #expect(channels.identity.uniqueDeviceID == "UDID-123")
        #expect(channels.identity.productType == "iPhone17,1")
        #expect(channels.identity.osVersion == "27.0")
        #expect(channels.identity.marketingName == "iPhone 16 Pro")
    }

    @Test("a reply with no services is not the directory endpoint")
    func emptyServicesRejected() {
        let notDirectory: DeviceObject = .object([("Properties", .object([("UniqueDeviceID", .text("x"))]))])
        #expect(ChannelBroker.parseDirectory(notDirectory, deviceAddress: "fd00::1") == nil)
    }

    @Test("opening an unsupported role reports the role, not a wire error")
    func openUnsupportedRole() async throws {
        let channels = try #require(parseDirectory())
        await #expect(throws: ChannelBrokerError.roleUnavailable(.deviceControl)) {
            _ = try await channels.open(.deviceControl)
        }
    }

    @Test("listed ports include services that back no role")
    func listedPortsIncludeUnmappedServices() {
        let reply: DeviceObject = .object([
            ("Services", .object([
                ("com.apple.coredevice.displayservice", .object([("Port", .text("51404"))])),
                ("com.example.unmapped", .object([("Port", .unsigned(51_390))]))
            ]))
        ])
        #expect(ChannelBroker.listedPorts(in: reply).sorted() == [51_390, 51_404])
    }

    @Test("shifting moves every role by the same offset")
    func shiftMovesEveryRole() throws {
        let moved = try #require(parseDirectory()?.shifted(by: 170))
        #expect(moved.port(for: .humanInput) == 51_573)
        #expect(moved.port(for: .mirror) == 51_574)
        #expect(moved.port(for: .hardwareControls) == 51_575)
        #expect(moved.port(for: .deviceControl) == nil)
        #expect(moved.identity.uniqueDeviceID == "UDID-123")
    }

    @Test("a shift that leaves the port range yields nothing", arguments: [-60_000, 20_000])
    func shiftOutOfRangeRejected(offset: Int) throws {
        let channels = try #require(parseDirectory())
        #expect(channels.shifted(by: offset) == nil)
    }

    private func parseDirectory() -> DeviceChannels? {
        ChannelBroker.parseDirectory(directoryReply(), deviceAddress: "fd00::1")
    }
}

/// Locating the device's live service block among its open ports.
struct LivePortResolverTests {
    private static func run(_ start: UInt16, _ count: Int) -> [UInt16] {
        (0..<count).map { start + UInt16($0) }
    }

    @Test("scattered ports outside the service block are never candidates")
    func dropsScatteredPorts() {
        let open = [49_152, 55_655, 55_703, 55_704, 61_770, 62_078] + Self.run(62_100, 85)
        #expect(LivePortResolver.serviceBlocks(open) == [Self.run(62_100, 85)])
    }

    @Test("a block split by a missed connect stays one block")
    func mergesSmallGap() {
        let block = Self.run(62_000, 40) + Self.run(62_042, 45)
        #expect(LivePortResolver.serviceBlocks(block) == [block])
    }

    @Test("a wider gap separates blocks, and the larger one is searched first")
    func ordersBlocksBySize() {
        let small = Self.run(50_000, 10)
        let large = Self.run(62_000, 85)
        #expect(LivePortResolver.serviceBlocks(small + large) == [large, small])
    }

    @Test("no open ports yields no blocks")
    func emptySweep() {
        #expect(LivePortResolver.serviceBlocks([]).isEmpty)
    }
}
