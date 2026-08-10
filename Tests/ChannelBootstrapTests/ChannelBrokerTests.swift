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

    private func parseDirectory() -> DeviceChannels? {
        ChannelBroker.parseDirectory(directoryReply(), deviceAddress: "fd00::1")
    }
}
